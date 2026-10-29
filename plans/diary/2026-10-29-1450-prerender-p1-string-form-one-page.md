## 2026-10-29 14:50 CET — Prerender P1: the string form, one page, replaced on load

**What I did** (#1165, part of #1160; a Claude agent, the slice's implementer)

- Built `prerender.md` §11's P1 row. The `inline` lowering writes, in the prerender tree, a render
  function in the mount's place (and `$$render$<n>` per piece, given its first arm's ordinal): the
  unit's string with each hole's value, a hidden eager arm as `<!--n-->`, `data-beni` on the top
  element, every end tag written. Escaping is `Inline.escape`, `escapePre`, `escapeAttribute`.
- Interface 1.20: `Lowering.prerenders`, `Build.prerender` (`none`/`tree`/`client`) and
  `programPure`, whose compiler side walks `init`'s and `view`'s bodies for an impure call
  (Debug exempt, own-module functions followed) and reports `prerender_impure`.
- `beni build --prerender` (hidden): the prerender tree into `.<out>.prerender` (entry
  `_prerender.mjs` exports `routes` and `render`; `_node.mjs` runs it and appends JSON records),
  run under the `node` on `PATH`, then the client tree, whose `{{view}}` gets the page — or
  `prerender_needs_node` / `prerender_failed` / `invalid_html_shell`. The client calls
  `Inline.unprerender` and mounts fresh.
- The driver's `--html-page` opens a page on the `index.html` the build wrote; the corpus kind
  `browser/prerender/` (Counter, HiddenArm, Escapes, Controls, Pieces: four builds each, one
  transcript) and `build/bad/prerender/` (five); a `prerender_needs_node` case and a `--jobs`
  determinism case in `tests/blackbox/`.
- Amended `prerender.md` where it met the code (§3.1, §4.1, §4.2, §4.4, §5.1, §5.5, §11 *As
  built — P1*), `boundary.md` §9.4.6 (1.20), `backend.md` §2 (`{{view}}`), `language.md` codes.

**What I learned**

- The cleanest prerender tree is the same `Emit.run` again with `Build.prerender = .tree`: the
  program hook returns the render function where it returned the mount, so `main` *is* the
  renderer, no reachability root is added, and a client tree never holds a byte of the string
  form. The doc's "the emitter roots the prerender tree at a render export" was more machinery
  than needed.
- §8.2's omitted end tags cannot be used by the string form: whether `</li>` may go depends on
  the next sibling, which may be an arm `init` hides. Writing every end tag is the same tree.
- Markup in `Bir` is a `.markup` instruction whose values `instChildren` does not list; an
  effect walk over a `view` must add `Bir.markupValues`, or `{Clock.now ⊤}` in a hole is missed.
- The harness gives `beni` an empty environment, so a prerendering build there needs
  `RunOptions.path`; an empty `PATH` is exactly the `prerender_needs_node` case.
- Node's uncaught-error text holds the tree's paths and Node's version; the diagnostic quotes
  only the error's own lines so the golden is the same on every machine.
- Debt: #1170 (another module's `init`/`view`, and Debug-only helpers of other modules, are
  refused by the purity check instead of read).
