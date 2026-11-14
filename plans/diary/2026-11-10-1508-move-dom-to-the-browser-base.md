## 2026-11-10 15:08 CET — Move Dom to the browser base

**What I did**

- Took over the `beni-base` lane from a Codex session, at its Time commit e9996a71ca.
- Moved `Dom` from `browser` to `browser-base`. It is re-exported by `browser` and
  `browser-inline`, and through `browser` by `browser-tea`.
- Added the private base module `Phase`. It holds the hosted loop's phase state that `Browser`
  held. `Dom.rendered` and HTTP's after-render wait go through it.
- Interface 1.28, `Lowering.Effects.after_render`: inline compiles `Cmd.afterRender`, also in a
  staged prerendered `init`.
- New fixtures: `browser/prerender/BaseDom`, and the refusals `build/bad/prerender/BaseDomInView`
  and `BaseDomInInit`. All three failed before the change (unknown module `Dom`).
- The manager accepted four `browser-tea` release goldens that change only in module order and
  short names (+6/+6/+6/−4 raw). They were recorded from a real build.

**What I learned**

- A top-level `Js.Ref` that is `pub` is always a `{ v }` cell in release. Moving the refs as
  `pub` added 20 bytes to every hosted page. Keep the refs private and give other modules
  functions instead: then they stay `let`s.
- `Task.onTurn` wraps the whole scheduler drain, not one fiber's turn. Under inline, the whole
  drain is one dispatch, so `Task.yieldNow` resumes the fiber before the page is written.
  BaseDom's "open" step showed it (`NotFound second`). A microtask resumes after the drain.
- A blessing run writes every golden that differs in its filter, not only the new ones. Filter
  it to the new fixture's path.
