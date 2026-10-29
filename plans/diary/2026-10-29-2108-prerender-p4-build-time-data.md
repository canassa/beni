## 2026-10-29 21:08 CET — prerender P4: build-time data

**What I did**

- Built slice P4 (#1218, part of #1160) as `prerender.md` §8 says: `"build"."data"`, node's
  `Prerender.pages` (beni over `Js`, one `impure` `foreign` that writes the records),
  `Browser.prerenderData` on `browser-inline`, the data program built as a second `Session` into
  `.<out>.data` and run under Node at the project root, the per-page
  `<script type="application/json" data-beni-data>` with `<` and every character past U+007E
  escaped, the tree's `render(route, text)`, the client's read of the script before `init`, no
  `index.html` but `/`'s, `--no-prerender` for a data site, and `serve`/`--watch` watching the data
  program's paths and `"inputs"`. Four new codes; lowering interface 1.23 (`prerender_data`
  placement, `Program.data`, `programDataSchema`, `programDataBind`).
- 9 `browser/prerender/` fixtures, 13 `build/bad/prerender/` ones, a serve scenario, and two
  `build_test` cases (another working directory with `Debug.log` under `--release`; determinism).
  Every fixture fails on origin/master's binary. `bench/size.mjs --pages-only` is byte-identical to
  master's; the data adds 1 040 B brotli to `DataBlog`'s release client.
- Rebased over P2b mid-way: the driver now runs inline scripts, so it had to skip the JSON data
  block as well as keep it. Filed #1237 (a release-build leak on an early Emit refusal).

**What I learned**

- The lambda of `Browser.prerenderData` never needs to exist: compiling the call as the lambda's
  body and letting the mount bind the parameter (`programDataBind`) before `init` keeps the element,
  the route and the hydration all in one place, and the tree's render just takes a second argument.
- `programInit` evaluates `λ⊤ → e` as `e` and never placed the ownership hoists made at the lambda;
  nothing read a captured record's field in `init` before, so it never showed. A page's value is
  exactly that.
- Markup holes are not BIR operands: any walk that looks for a local must add `markupValues`, as
  `effectOf` does, or a `view` reading the value slips past.
- `--root` is the module-name source root, not a project root: the data build must drop it, or its
  paths become invalid module paths.
- Printing a whole `Url` in a page fixture breaks under headless Chrome, whose server port differs
  from the origin's; print the path and query.
