## 2026-11-05 06:34 CET — close four v2 soundness holes before #1954 merges

**What I did**

- Fixed the four soundness holes the S4 audit found in `--ownership=v2` on the slot domain, one commit each on
  `own2-holes-r4`, rebased on `own2-slot-pr`:
  - #1955 `UnknownCellReentry` (a regression of the PR; v1 refuses): a capture write of a code run at a callee's
    label now has the call's other arguments (through every `◆`) and the call's other labels' answers as operands,
    at every label outward (`Across.zig`, §2.11.3). The same hole through another label's answer (`AnswerAcross`,
    a list) was v2-only too and falls with it.
  - #1955 `StoredCaptureEdited` and its `Ref.modify` twin: the answer's objects at a shared slot escape at the
    call, and the rule applies at every label supplied one cell's contents, so `upd r f = Ref.update r f` and
    `Ref.update r λxs → f xs` helpers are covered (`Stored.zig`, §2.13.7). Both shapes through a helper were
    holes too.
  - #1956 `PatternStoredBack` `viaL`: `[*]` and a front, back or slice position at one parent are related now
    (§2.3.2). It also refuses `PushedPositions`' `editSpread` (`[ …xs, el ]`), which base v2 accepted unsoundly
    (v1 too). A slice of a spread literal drops the kids it skips, so `[ el, …xs ]` then `[ _, …rest ]` stays
    accepted.
  - #1956 `OnceOtherHolder` `tuple`: an occurrence at a function's slot is deep (`Distinct.deepAt`,
    `Canon.wild`), so a selection takes a closure's captures (§2.9.1).
- Fixtures: `run/SanitiserCellReentry`, `SanitiserCellStoredCapture`, `SanitiserPatternStoredBack`,
  `SanitiserClosureSlotHolder`, each with `.sanitize-lists-v2-refuses` and an accepted `…Apart`/`…Fresh` twin.
  Each red fails on the base (refusal set differs, or the sanitised run shows the stale read).
- v1 (frozen) is left to #1956 and #1959: its model has no positions or slot occurrences to fix in a small,
  clearly sound change.
- The two test points of the re-review of #1954: `GroupMutualRing` asserts rounds ≤ 3 and growth 0 a member; the
  accumulator test asserts growth 0. Both fail with the bound mutated.

**What I learned**

- Ledger (2 194 roots) against `own2-slot-pr` at `25a07850d9`: accepted→refused 2, both `PushedPositions(Imported)`
  `editSpread`, the shape `run/SanitiserPatternStoredBack`'s `viaSpread` traps on at the base; 4 refusals change
  their reason (`disjoint` operand → path); nothing else moves. Cost table identical.
- Probe sets (1 015 dirs: slot-build/oracle, slot-probe{,2,3}, review-1954, audit4, mine): 0 TRAP, 0 DIFF. Three
  probes go from accepted to refused: `ReentryList` (twice) and `ReentryNoLoanGreen`, safe programs v1 refuses
  too. The caller-side operand rule is coarser than a callee-side "held across the label" record would be.
- A holder index or the `Within` index (more than eight entries) may still treat `[*]` and `front k` as apart
  where they bypass `Frame.related`; no probe found one.
