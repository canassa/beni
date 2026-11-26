## 2026-11-23 20:10 CET — helper branches on browser-inline

**What I did.** #2498, part of #2628 and #966. `browser-inline` now compiles a view helper whose
body is an `if` or a `case` (`browser-inline.md` §8.4, *A view helper whose body is a branch*):
the hole that calls it is the call's context, its parameters bound and no markup root of its
own (`Ctx.bare`), and inside it the callee's branch compiles exactly as the same branch written
at the hole would — eager `when`s, or a branch region. Interface 1.34 adds
`Callee.Refusal.branch`; `Lower` reads the callee's branch from the call's frame and adds no path
step for its arms, since the call's frame already extends the path. Pages: `browser/inline/
HelperCase*` (each run on `browser-tea` as the oracle: the same transcript but for empty
placeholder nodes), a copy of `browser/tea/Routes`, and `browser/prerender/HelperBranchOpens`
(`ArmOpens` through a helper, the same page and transcript). Five refusals in
`build/bad/inline/HelperBranch*`. The sweep of the `browser/tea` + `browser/dom` pages on
`browser-inline` went from 143 to 144 (`Routes`); `EmptyMarkup`, `ShowAndBranches` and `TodoMVC`
now stop at later limits, and `TemplateChoices`/`TemplateControlLists` call another module's
helper (a piece), which this slice does not touch.

**What I learned.**
- The issue's 2026-11-11 design (eager `when`s only) predates branch regions. Composing the
  helper with §8.2 as it stands gets the `Just draft → <input value={draft}>` shape of TodoMVC's
  `editor` too, with nothing new in kind.
- A helper's arm is a markup root of its own, so a `let` in the arm is a `Root.lets` entry, not
  an input as in the `view`. Two checks only looked at inputs: `eagerArm` called such an arm
  eager (its `let` then ran at every event), and `armStatements` either refused a read `let` or,
  after the first fix, accepted an unread one and dropped its effect. The adversarial review
  found both with page programs; both are fixed and pinned (`HelperCaseArmLet`,
  `HelperBranchStatement`).
- The `when` form is 45 B of brotli above the same `case` in the `view`: the empty bucket of the
  call's argument group (#2500), which every view helper's call pays.
