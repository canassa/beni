## 2026-10-29 13:39 CET — prerendered pages for browser-inline, specified

**What I did.** I opened #1160 and wrote `docs/design/prerender.md`, with pointers in
`browser-inline.md` §1, `boundary.md` §5.2, `backend.md` §2 and `frontend.md` §10.4 (PR #1161, not
merged; it is for the owner). The design:

- It is a build of `browser-inline`. The `inline` lowering gets a string form of each view.
- The build emits a prerender tree, runs it under Node, and writes the pages itself through
  `pending`. The shell gets `{{view}}`.
- A hydrating mount finds the unit by `data-beni` and rebuilds the element tables. It merges the
  page's elements with the template's elements for each arm hidden at init. Each hidden arm is a
  `<!--n-->` comment, and that comment is the arm's anchor.
- `Tea.application` and `Browser.prerender` give a page per route.
- The slices are P1 (string form, one page, replaced on load), P2a (hydration), P2b (input
  before the takeover), P3 (routes) and P4 (build-time data).

There are four questions for the owner: may the build run Node; what `init` receives; a fresh
mount or a stop on a tampered page; does `serve` prerender. One adversarial reviewer found ten
problems, and I fixed every one.

**What I learned.**

- `browser-inline`'s bindings compare before they write, so a prerendered text or property that
  differs heals in the first pass. Only structure needs a check, which is where it differs from
  Solid's position-only claim.
- The fresh mount finds elements three ways: the program table, the piece tables (`part`) and
  `firstChild` paths. A hydrating mount must build all of them from one merged table.
- Solid's replay of early events depends on its event delegation. beni attaches a listener to
  each element, so only the capture carries over.
- `Debug.log` is `console.log`, which writes to Node's standard output. So the prerender records
  cannot use that stream.
- A schema does not promise `decode (encode x) == x`, so build-time data must be rendered from the
  decoded value in the build too.
- `references/dom-expressions` and `references/solid` are empty in a fresh worktree. Read them in
  the main checkout.
