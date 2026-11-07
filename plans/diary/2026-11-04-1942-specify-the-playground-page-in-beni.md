## 2026-11-04 19:42 CET — Specify the playground page in beni

**What I did**

The first pull request of #142, spec only. `docs/design/playground.md` gets §10: which of the nine page files becomes what, a split of `wasi.js` (a typed WebAssembly module, privileged; the file system and the 46 WASI functions, beni of the page), the playground's own platform for CodeMirror and the frame runner, the order of the later pull requests, and how the page works during the move (the remaining JavaScript imports a `--library` build of the beni that has landed). `docs/design/boundary.md` gets §9.13: each host API that a platform or `core/` must give, its home, and the failures that its wrapper must type. I opened 16 issues for the gaps (#1881 to #1894, #1896) and asked the owner four questions on the dashboard (`playground-beni-q1` to `q4`). The baseline size of the nine files is 78 638 bytes, 22 422 at brotli quality 11.

**What I learned**

- `browser-direct` was not renamed. The owner retired it on 2026-10-19 (#423), and `browser-inline` replaces it. Today `browser-inline` has no `Http`, `Time`, `Dom` or `core/Task`, so the page's platform is a real choice (`q1`).
- Two of the gaps that #142 names are owned elsewhere already. A Web Worker is `Browser.Worker` of the workers delivery (#1612, #1297, `workers-api.md` on PR #1304). Bytes, `DataView` and 64-bit word pairs are `Binary` of #1278 (`webgpu.md` §3.1). That design also settles WASI's `i64`: word pairs, not an `Int64` type.
- `Js.module` takes only `node:` and `cloudflare:` built-ins, so a platform cannot import a vendored third-party module from beni (`q4`, #1882).
- No markup form leaves the inside of an element to a library, so CodeMirror cannot live in a Tea view yet (`q3`, #1881).
- `Dom.scrollIntoView` takes no options. The page needs `block: "nearest"` (#1896).
