## 2026-10-08 21:20 CEST — Write-set spec: the third review's gaps closed

**What I did**
- Amended `docs/design/write-sets.md` for the third review of PR #18, which found nothing
  unsound (branch `write-sets-spec`, not pushed). §9.1's baking rule is now an allowlist of
  ordinary flow-content parents, so text the HTML parser foster-parents or drops (`table`,
  `tbody`, `tr`, `select`, …) is never baked; §4.4 says a `case` whose scrutinee path already
  carries a decided tag fact adds no children, so two sequential `case msg` expressions give
  three leaves, not nine; `List.update`'s callback element is bound to εⱼ like `map`'s so a
  field write rebases to `node p[κ]; value p[κ].f`; §5.1 notes that `γ(Rec)`'s "every other
  field" clause is vacuous for a full record with no base. Two fixtures added to §8.3 (items
  16–17). Gates green (docs only).

**What I learned**
- A denylist of HTML parents is the wrong shape for a rule the template walk depends on: the
  parser's exceptions belong to the parser, and the only safe claim is "these parents keep
  their text where it is written".
