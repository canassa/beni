## 2026-10-29 16:58 CET — hydrate prerendered browser-inline pages

**What I did**

Built slice P2a of `docs/design/prerender.md` (#1178, part of #1160). The client of a
prerendering build now takes the page over through one runtime function, `Inline.take`, written in
beni over `Js`. It finds the unit by `data-beni` as a child of the mount element. It merges the
page's elements with each hidden arm's elements, which it makes from the unit's string, into the
table a fresh mount makes. The arm's `<!--n-->` comment becomes the arm's `when` anchor. Every piece
table is a slice of the merged table, and the mount reads no `firstChild` path and mounts no root
run. Before it binds anything, it checks the page: the tags of the elements code refers to (every
tag in development), the element count, and each arm comment's place (its parent, and between the
page elements around it). On a difference it takes the unit out and mounts fresh in the same task,
with a warning in development. `{{view}}` outside the mount element is a development fault and a
fresh mount in release. The interface did not change.

The `browser/prerender/` kind now marks every element before load and checks after the mount that
none was replaced (or, with the new setup step `fresh`, that none of the unit is left). The new
setup steps `inject` and `retag` edit the page before load. A normalisation prints the control
attributes and anchor comments a taken-over page keeps as a fresh page shows them. A build can have
a golden and steps of its own. New fixtures: `Tampered`, `Retagged`, `RetagUnseen`, `ArmOpens`,
`PieceArm`, `LoneElement`, `WrongPlace`, and `emit/prerender/` and `emit/release/prerender/`. All
of them fail against master's P1 client, and they pass in happy-dom and in headless Chrome.

`bench/ui/hydrate.mjs` measures beni against Solid 2's `hydrate` of its own `renderToString` page.
On three pages, beni is 3–4× faster from the module's start to the handlers attached, and its
hydration adds 583–687 B brotli against Solid's 1 439 B.

**What I learned**

- `git checkout origin/master -- <file>` for a red-first proof overwrites uncommitted work in
  that file, so commit before you do it. I lost the two source files once and wrote them again.
- `git checkout <branch> -- .` onto a newer base reverts every file the base changed since. Check
  `git diff --name-only <old> <new>` and restore those files.
- The driver already had an `insert` step (it types at the caret), so the page edit is `inject`.
- Solid 2's `hydrate` needs `generateHydrationScript()` in the page's head (it sets `_$HY`).
  Without it, `hydrate` throws.
- A piece may be shown at only one place, so `PieceArm` uses two modules.
