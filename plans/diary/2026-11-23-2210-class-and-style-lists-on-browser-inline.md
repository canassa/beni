## 2026-11-23 22:10 CET — class and style lists on browser-inline

**What I did.** #2499 and #2635, part of #966. `browser-inline` compiles a class list and a
style list written in place, a `style` of a `String`, and, outside `For` rows too, an attribute
that is no DOM property whose `String` or number value changes (`browser-inline.md` §8.2, *A class
or style list, …*, amended 2026-11-23). The class list is the design of lane `beni-markup`
(2026-11-11, never merged), ported by hand onto today's `inline.zig` and extended to rows and
branch arms: constant entries are baked, each changing entry is a runtime `toggle` or `style`
call that compares with the node first. Eight `browser/tea` pages copied to `browser/inline`
(six with tea's transcript, `PointerInput` and `SharedSite` with listed differences); six new
pages (four with `browser-tea`'s transcript, two with a listed difference); a prerendered
`ClassList`; one release golden; five refusals. The inline sweep of the 357 `browser/tea` +
`browser/dom` pages went from 154 to 162 with the same script on the same master.

**What I learned.**
- The "class or style" refusal counted three pages that only had a constant `style="…"`: the
  `f.styles` test refused every `style`, the `String` form included.
- `TodoMVC`, `TodoRouting` and `Blocks` now stop at later limits (a branch in a `For` row, a
  text hole beside an element, a region followed by text); `HolesInPlace` at a class list held
  as a value, which needs `language.md` §11.19's runtime diff.
- The adversarial review found one defect: a toggled class name in a prerendered page was not
  escaped (`a&b`, `q"x` broke the attribute). Fixed and pinned in `browser/prerender/ClassList`.
  It also found where the transcripts part from `browser-tea`: a node inline keeps and tea makes
  afresh (an eager arm, an unkeyed row) keeps its class order, and a style list with a shorthand
  and its longhand keeps the longhand where tea loses it. Both are listed in §8.2 and pinned
  (`ClassListEagerArm`, `StyleShorthand`).
- An `if` whose arms read only the model is an eager `when`, not a region: to test a list in a
  region's arm, the arm must read what the branch binds.
