# Vanilla TodoMVC baseline

Unchanged `examples/vanilla-es6` from [tastejs/todomvc](https://github.com/tastejs/todomvc/tree/302b409c2b8510dc634fdd0e481196845109dc97/examples/vanilla-es6),
commit `302b409c2b8510dc634fdd0e481196845109dc97`. `upstream.json` pins every source
and the original HTML by SHA-256. `vanilla-build.mjs` verifies them before
bundling with pinned esbuild 0.27.0. No CSS or todomvc-common/base.js is priced,
as in `size.mjs`; the app's static HTML is served separately and its bytes are
reported beside JavaScript. The original app retains editing, hash routing,
and JSON localStorage persistence. Beni's routing comparison omits editing
and stores lines; the sandbox has editing but no persistence or routing.

From the repository root:

```sh
direnv exec . npm ci --prefix bench/todomvc/apps/vanilla-es6 --no-audit --no-fund
direnv exec . node bench/todomvc/vanilla-build.mjs
direnv exec . node bench/todomvc/direct-size.mjs --beni=zig-out/safe/bin/beni
direnv exec . node bench/todomvc/direct-time.mjs
```

The timing batch rotates subjects and uses real Chrome input at 100 and
1,000 todos. Add commits on Tab (`change`) for vanilla and Enter (`keydown`)
for beni. Toggle's beni update is in `change`, after the `click`; the timer
includes it. Every result verifies row counts and persisted state. Traced
and untraced rows are separate; tracing is never mixed into the untraced
median. Each sample starts on a fresh page, warms six toggles, and records
machine load. Raw samples, compiler-output hashes and Chrome version are in
`bench/todomvc/results/`.
