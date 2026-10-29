## 2026-10-29 18:52 CET — prerender slice P3: routes

**What I did**

- Marked `prerender.md` §10 questions 2–4 decided (the owner: "go with the recommendation").
- Built slice P3 (#1194, part of #1160): `Browser.prerender program routes` on `browser-inline`,
  recognised on `main`'s spine and compiled away in the client tree (interface 1.22: placement
  kind `prerender`, `Named.routed`, `Build.address`); `browser`'s `Browser` (and so `browser-tea`)
  got the identity. The build reads `main` after checking to decide whether to prerender, so the
  hidden `--prerender` is gone and a hidden `--no-prerender` serves the corpus comparison.
- One page per route (`/about` → `about.html`, `/blog/` → `blog/index.html`), `invalid_route`,
  `output_path_collision` for routes (folded, and file-versus-directory), `prerender_needs_origin`,
  `"build"."origin"`, `{{title}}`, documents and applications prerendering, the route in
  `data-beni`, `init` handed the route's `Url`, the address sent after the first render through
  `Browser.Navigation`'s own announcement, `beni serve`'s `<path>.html` rule.
- Fixtures: `browser/prerender/Blog`, `Titles`, `browser/tea/PrerenderedBlog.beni`, six
  `build/bad/prerender/Route*` and `NeedsOrigin`, a serve scenario; the existing prerender
  fixtures moved to `Browser.prerender`. The driver opens the page a host serves for the script's
  `url`.

**What I learned**

- Reachability is BIR-based, so compiling a call away in the lowering is not enough: the callee
  and the list still ship unless the emitter cuts them (`Reach.Cut`). The first build shipped
  `Browser.prerender` and the posts in the client.
- `Url.percentDecode` was inferred impure (`Js.catchIf`), which made every `Url.Parser` segment
  parser impure and so every routed `init` `prerender_impure`. Marking it `Js.pure` changed no
  emitted code, only source maps and the interface's purity column.
- `browser-inline`'s handler limit refuses an `update` that reads a field of a `Url` message
  (`url.path`); going through `Url.Parser` or `Url.toString` avoids it. The routing skill's example
  is such a program, which `beni check` accepts and the build refuses: #1202.
