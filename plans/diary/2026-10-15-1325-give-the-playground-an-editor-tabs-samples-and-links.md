## 2026-10-15 13:25 CEST — give the playground an editor, tabs, samples and links

**What I did**

Issue #128, second pull request, on top of the first. The page now edits
with CodeMirror 6 from esm.sh, every package pinned in an import map, and
highlights beni with a small stream grammar (`playground/syntax.js`). The
compiler's JSON diagnostics are lint marks at their places, and a list under
the editor selects each one. The Types and Ownership tabs run their dump
while open. Three samples build for `browser-direct` today: a counter,
TodoMVC (copied from the benchmark at build time), and a printing program.
Share puts the source, deflated, in the fragment.

I also answered the review of the first pull request: the host's crash rule
now matches only an exhausted engine stack, files are bounded at 1 GiB, every
WASI preview 1 function exists, the console keeps 2 000 pieces of output,
`serve` is refused by a build with no threads, and the Node driver deletes
removed files.

**What I learned**

- Chrome 153 runs a sandboxed `srcdoc` frame without `allow-same-origin` in
  a process of its own. The DevTools page session does not list it as a
  child frame; `Target.setAutoAttach` hands it over as an `iframe` target.
- esm.sh's `*` form keeps a module's imports bare, so one import map pins
  every CodeMirror package once. A CDN that resolves each package's version
  ranges alone can load two copies of `@codemirror/state`.
- CodeMirror's `StreamLanguage` takes highlight tag names; `special` is a
  modifier and not one, so interpolation delimiters are `meta`.
- Typing through `Input.insertText` and opening pages from links made with
  the page's own `share.js` drive the editor with no hook into CodeMirror.
