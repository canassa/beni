# Compile-to-vanilla experiments (#172)

Research only; no compiler or normative language changes. `generate.mjs` is a
small, explicit dependency IR -> JavaScript experiment, not a beni compiler.
The experiment contract is specified here before implementing it.

Compare six outputs: manual direct writes (`vanilla`), static local patch calls
(`lexical`), a sparse indexed consumer table (`indexed`), runtime dependency
tracking (`signals`), whole-page patch scanning (`scan`), and lexical factories
expanded per feature (`expanded`). All share DOM construction, model operations,
precise host error handling, a defect guard and lifetime handling. Thus this
isolates scheduling/representation, not six independent frameworks. Signals is
a tiny experimental graph, **not Solid**; indexed is **not today's direct**.

Six families: CRUD lists, controlled forms, fetch/decode/hash routes, a board,
independent dashboard widgets, and shared-state fanout. Measure 1, 4, 16 and 64
features with repeated and varied shapes. Varied shapes have distinct names,
constants, expressions and dependency sets; they are still generated synthetic
features, not an estimate of arbitrary application growth. Runtime population
is a separate parameter. Fit brotli bytes = intercept + slope * features;
retain raw observations and residuals. One production response, Terser with the
same options for every candidate, brotli 11 with size hint and gzip 9. No source
maps, HTML shell or benchmark driver in the byte count. HTML templates in JS
count. Report the actual one-feature size as well as the fitted intercept.

Run each generated production page in headless Chrome. Assert state through DOM
observations, including rejected edits, row identity, request failure and stale
completion. Time DOM event batches and a layout read, separately from network
work. Retain samples, host/tool versions, source hashes and deterministic order.
These pages exercise a subset of beni's guarantees; they do not price full Task,
all HTTP errors, navigation, arbitrary component values or the ownership checker.

## Reproduce

From the repository root (Node 24; a locally installed Chrome or Chromium):

```sh
npm ci --prefix bench/compile-to-vanilla
node bench/compile-to-vanilla/build.mjs
export CHROME='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
# Linux: export CHROME=chromium
node bench/compile-to-vanilla/browser.mjs --verify
node bench/compile-to-vanilla/browser.mjs
node bench/compile-to-vanilla/edits.mjs
node bench/compile-to-vanilla/prepare-ui.mjs
npm ci --prefix bench/ui/apps/solid2
(cd bench/ui/apps/solid2 && npm run build && ENTRY=static npm run build)
node bench/compile-to-vanilla/table.mjs
node bench/compile-to-vanilla/static.mjs
node bench/compile-to-vanilla/report.mjs
uv run bench/compile-to-vanilla/plot.py
```

Run timing scripts sequentially on an idle machine. The full grid builds 306
pages and verifies each. Its timing pass records 1,188 samples (nine fresh pages
per cell, two warm batches then one measured batch), with rotated candidate
order. The array experiment records 54 pages, the table 108 and the static-heavy
page 27. `out/` is regenerated and ignored; source, locks and raw results are
committed. The figures use pinned matplotlib via uv's script environment.

Serve this directory after building, and open, for example,
`out/dashboard-varied-lexical-64.js` to inspect the production output, or the
corresponding `.source.js` for the readable output. To run a page manually,
use a shell with `<div id="app"></div>` and load its JS as a module. Route pages
need the `/api/` fixtures in `browser.mjs`; they are not a general HTTP demo.
`browser.mjs` serves that shell and fixture API during the automated run.

The report is [research 105](../../docs/design/research/105-compile-to-vanilla.md).
[`results/tables.md`](results/tables.md) contains every size point, fit and
per-operation timing summary. `sizes.json` retains residuals, raw/gzip/brotli
bytes and all bundle SHA-256s; `verification.json` binds DOM checks to those
hashes. `timing.json`, `edits.json`, `table.json` and `static.json` retain raw
samples and browser versions. The independent table's byte counts exclude its
external shared static HTML; use the generated family grid for size comparisons.

The family grid shares DOM/model helpers to isolate representation. Its manual
candidate is not an independently optimized vanilla application. The separate
array experiment's generic reconciler is cursor-based, not an optimized
crossed-end/LIS algorithm. The report attaches these limitations to the claims.
