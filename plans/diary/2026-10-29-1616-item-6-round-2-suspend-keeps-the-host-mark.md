## 2026-10-29 16:16 CET — item 6, round 2: Suspend keeps the host mark

**What I did.** The second review's round 2 of #1127 found one defect left in the F2 fix:
`Suspend.clone` copied a `call` with `addParts`, which resets `JsIr.Node.host`, so the rest of
a tail-call loop copied after a park printed a `Js.apply` lambda as its callee — release `10 NaN
2` against development `10 10 10` on the reviewer's probe. Spec first (`backend.md` item 6,
dated): `Suspend` keeps the mark as `Spec` does; the rule "a `const` holding an import is never a
callee" holds in the module that declares the alias, since `Opt` runs per module, and another
module's alias is a callee, harmless today by `boundary.md` §4's checks 3 and 4; the hand-written
bullet carries its second date and says `77ee6b72a` came a day before its text; a `const` of an
enclosing function qualifies, as the code takes; an emitted function reads `this` only when
`Js.method` made it. Then the fix (`hostOf` + `markHost` on the copy), the alias walk's `return`
at its bound, `run/EtaReduceHostSuspend` (red first, on the current compiler), and
`emit/release/core/EtaReduceAlias`, a two-module core project that pins the cross-module shape.
Both PR bodies now say the pages row measures 296 of 419 fixtures; `pages.mjs` is fixed (a
project's files were made relative twice; a top-level fixture was copied as `Page.beni`, the page
platform's own module name) and the whole corpus is queued for re-measurement.

**What I learned.** Every copier of a node is a place a column can be lost: `Spec` had two and
`Suspend` a third, and the column's doc comment is where the list belongs, so a reviewer can
check it against `grep addParts`. A rule that `Opt` enforces is a per-module rule, and the spec
must say so when the printer's whole-program knowledge is what the rule leans on. A measuring
script's "N pages" is a claim about the corpus: print how many were not built, every time.
