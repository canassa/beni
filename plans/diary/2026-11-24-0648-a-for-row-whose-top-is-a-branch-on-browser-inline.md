## 2026-11-24 06:48 CET — A For row whose top is a branch on browser-inline

**What I did.** Compiled a `For` whose row function is a lambda whose body, past its `let`s, is
an `if` or a `case` (part of #2637): the row's node is the arm it shows — an element, a view
helper's element, or an empty comment for `<></>`, as `browser-tea` keeps one. `Lower`'s
`branchArms` takes the `For` node and gives the row lambda's body as the branch (interface
1.38); the row is made by the runtime's `emptyRow`, and its `set` chooses the arm with the
item bound and hands `rowArm` the arm, which swaps the row's node with `replaceWith` and keeps
it as the row's `n`, so `forRows` moves, focuses and removes whichever node a row shows. Spec
`browser-inline.md` §9, *A row whose top is a branch*. Page `browser/inline/RowTopBranch`
(raw transcript equal to `browser-tea`'s, dev and release), `emit/release/inline/RowTopBranch`
(2 579 B raw, 1 225 B brotli), `build/bad/inline/RowTopBranchFragment`; `EmptyMarkup` and
`WholeFor` copied from `browser/tea` with their listed differences of nodes. Sweep 196 → 198.

**What I learned.** A row whose node changes needs nothing of `forRows` but that every reader
of a row's node read `row.n` at the time, which it already did. The review found the first build
refused `let`s before the `if`, which the spec allowed: `RowSource.body` of a lambda row keeps
its `let`s, so the check must look past them. A page's `List.push` on the model is a v1-only
entry demand, listed in `ownership-v2-known.txt` as the `browser/tea` copies are.
