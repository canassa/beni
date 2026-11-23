## 2026-11-23 17:21 CET — markup values on browser-inline

**What I did.** Part of #966. `browser-inline` now compiles a markup value that names a root:
a `let` or a constant whose value is markup written in place, a helper argument written as
markup or such a constant, and a helper or `view` whose result is such a `let`
(`browser-inline.md` §8.2, *A markup value*). Each hole that shows the name enters the root in
place, as a view helper's call is; nothing evaluates or stores it, so there is no identity to
compare (rule 8). A constant is also a branch region's arm. Any other read of the name is
refused. Pages: `browser/inline/MarkupValue*` (each one also run on `browser-tea` as the
oracle, with the same transcript but for `browser-tea`'s comment nodes and text splits), and
copies of `browser/tea/LetOneOwner` and `LetMarkupHandler`. `build/bad/inline/HelperMarkupArg`
and `CaseValueArm` compile now and are pages; three new refusals. The sweep of the 357
`browser/tea` + `browser/dom` pages on `browser-inline` went from 139 to 141.

**What I learned.**
- The write-set pass walks each kind of name on a different path: a constant on the path its
  hole extends (`topValue` walks it freshly in view mode), a `let` where it is bound, an argument
  where the call's arguments are evaluated. Entering the root must add a step for the first only.
- The adversarial review found that an argument's markup reading a `let` of the caller built and
  threw `ReferenceError`: the caller's `let`s are bound where the caller's values are, not
  where the helper's hole enters. That shape is refused now (`MarkupArgumentReadsLet`).
- Most of the 23 "no markup value" pages are other shapes: a helper whose body is a branch
  (#2498, stale), a `Maybe (Html msg)` hole, a document through a helper, `Html.map` in the
  program's module. They are listed in #2628.
