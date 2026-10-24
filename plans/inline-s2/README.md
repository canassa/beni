# S2's target output, priced

The evidence behind `docs/design/browser-inline.md` §9.7 (2026-10-25, #298). Nothing here is read by
a gate.

- `target/` — the target, readable, at big-table N = 1 seed 1 (`t1.js`, the row list `rows.js`,
  core's `Dict` subset `dict.js`, the app's pushes `app.js`, the runtime): `big-table/` with the pair
  index (the owner's question 3), `big-table-decided/` with the index as decided; and one
  unique-components list widget, `unique-components/w1.js`. `target/tea-inline/` holds
  tea-inline's files for the same apps, side by side.
- `emit/bt-s2.js`, `emit/uc-s2.js` — copies of the research project's tea-inline emitters for
  big-table and unique-components, with switches that change the output one decision at a time.
  The research project is not edited; these run against it read-only.
- `tools/` — `gen.mjs` (generate and build one app outside the research project), `measure.mjs`
  (its `measureBuild`), `sweep.sh` and `fit.mjs` (sizes 1, 4, 16, 64, 256 × seeds 1–3, then the
  fit), `check.mjs` (its script check with the same-task pass, against a scratch build),
  `bench.mjs` (its event timing), `micro.mjs` (the removal micro-benchmark), `nopoly.mjs` (the
  share of Vite's preload polyfill).
- `cpu.md` — the bench runs.

## The switches (`S2=<letters>`)

| | big-table (`bt-s2.js`) | unique-components (`uc-s2.js`) |
|---|---|---|
| `g` | synchronous passes inside beni's dispatch guard (D3) | — (S1's) |
| `d` | rows in a `Dict` (decided index), rows parallel to the entries, edits, forward reconcile | list items in a `Dict`, `at` edits, LIS `sync` |
| `m` | a lazily built key → row map instead of parallel rows | — |
| `l` | LIS in place of the forward pass | (always) |
| `y` | `selected : Maybe Int`, boxed | — |
| `v`, `h` | typed pushes; `h`: one shape row per table and one shared reader | — (S1's) |
| `c` | code-point `len` | — |
| `w` | edits at the write; `Select` checks its row | (always: every arm edits one key) |
| `p` | the pair index and a key → row `Map` | the same |
| `t` | — (big-table rows are templates already) | rows cloned from a template |

## Rebuilding a number

```sh
export RR=/path/to/reactivity-research S2DIR=/path/to/scratch   # S2DIR: outputs, never the research repo
cd plans/inline-s2
S2=gdlyvhcwp node tools/gen.mjs big-table "$PWD/emit/bt-s2.js" 1 1 "$S2DIR/out/a" && node tools/measure.mjs "$S2DIR/out/a"
bash tools/sweep.sh big-table "$PWD/emit/bt-s2.js" - gdlyvhcw gdlyvhcwp > "$S2DIR/bt.tsv" && node tools/fit.mjs "$S2DIR/bt.tsv" 4
S2=gdlyvhcwp node tools/check.mjs big-table "$PWD/emit/bt-s2.js" 16 1 rows=40
```

`-` is tea-inline's output unchanged (the copy reproduces it within ±6 B of HTML noise, the asset
name). The research project was at `87677ae` (the review rechecked three numbers at `1012209`, within 3 B), Node 24.19.0, its pinned Vite. Keep `S2DIR` off `/tmp`, which is RAM-backed here: `~/.cache/beni-agents/…`.
