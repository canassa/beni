## 2026-09-23 22:35 CEST — row 75: late derived parts become part sites; untyped own methods refused

**What I did**

- The review found a program 875f623 refused that row 72 compiled to a wrong
  answer. `M.T` holds a function, and there is an unannotated `pub eq`. Inside
  an unannotated `pub compare`, the `let` holds `{ v = left } == { v = right }`.
  It printed `not lt`, where `lt` is right. The review read it as row 75's
  ordering defect. Its real cause is different. When the comparison is solved,
  `left` is still a flex, so `targetFor` wrote `part 0 err` and `Lower` answers
  an `err` part with a structural `Basics$eq`. The `T = T Int Int` twin was
  already wrong on 875f623. So was `pair l r = let s = ( l, 0 ) == ( r, 0 ) in s`
  at a type with a custom `eq`, whose promoted evidence parameter the part
  never used.
- Fixed that class properly (A.86). The constraint the flex arm attaches now
  carries a PART SITE: `parent = part_site_parent`, `evidence_index` into
  `Solver.part_slots`, which holds the absolute part index. `fillPart` tells
  `targetFor` which part it fills. `emitSites` writes a part site's answer
  into its part. A named method is re-resolved in part form, so it carries its
  own evidence. `siteOrigins` skips part sites, and site de-duplication
  compares `parent`. `dispatch/ErrParts`'s `crossed` part moved from `err` to
  `strict_eq`; its intent comment was rewritten and the golden re-blessed.
- The own-method ordering form (an early group's `==` on a type whose
  unannotated `pub eq` comes later) is option (b): refused with the new
  `method_needs_annotation` (§10.12). It is catalogued in `language.md`,
  `checker.md` and static-dispatch. `js/Lower.zig` now refuses an `err`
  site as `internal` instead of emitting `undefined`: Lower only runs after a
  clean check, so such a site had no diagnostic.
- Fixtures `run/DerivedPartTypedLater/` (function-holding, plain and promoted
  forms; round-2 binary prints `False False False …`) and
  `check/bad/MethodNeedsAnnotation/` (round-2 binary: `check` exit 0). Gates:
  468/468 unit, 288/288 black-box (33/33 steps), fmt-check green. Queue row 75
  narrowed to "part form fixed; own-method form refused". Nothing committed.

**What I learned**

- `err` in a part had two meanings: a position nothing inhabits, and a
  position not yet known. `dispatch/ErrParts` pinned the first meaning and
  itself documented the second (`crossed`) as "harmless". It was harmless
  only while no type in the comparison had its own `eq`.
- A site-level answer and a part-level answer differ in where the callee's
  evidence goes: child sites of the instruction versus the part's own
  `parts`. Re-resolving through `targetFor` at answer time is simpler and
  safer than translating one form into the other.
