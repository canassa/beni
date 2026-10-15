## 2026-10-12 22:36 CEST — beni in the official js-framework-benchmark runner

**What I did.** Vendored krausest/js-framework-benchmark as a shallow, sparse submodule pinned to
`44f20790` (the commit that published Chrome 154) and added `beni-tea` and `beni-direct` as keyed
entries in `bench/jfb/frameworks/`; their `src/Main.beni` is a symlink to `bench/ui/apps/beni`.
`bench/jfb/run.mjs` copies everything into `bench/jfb/work/`, runs each framework's own `npm ci &&
build-prod`, checks the beni entries with `isKeyed` and `isCSPCompliant` (both pass, no notes),
runs `benchmarkRunner` at its default counts under `taskset -c 8-15,24-31`, re-runs failed pairs as
the README says, and builds their results app. I ran three full passes against vanillajs, Solid
1.9.3, Svelte, React hooks, Vue and Elm. Research 83 has the tables.

**What I learned.** The runner measures one framework's 15 iterations back to back, so a load
burst lands on a single cell. Load went past 24 in every pass (peaks 33, 41 and 40), and
paint-dominated `total` follows it: vanillajs `create10k` read 922 ms at load 10 against beni's 650
at load 5. Pass 3 was mostly quiet. Its official weighted geomean is beni-tea 1.08, vanillajs 1.17,
beni-direct 1.24, Svelte 1.26, Solid 1.47, Vue 1.47, Elm 1.76, React 1.84. On the quiet operations
beni is within 10 % of vanilla in `total`. Memory and size are stable across all three passes:
beni is right after vanilla on memory, and beni-direct's 4.4 kB is level with Solid's 4.5. `script`
agrees with bench/ui's port where both were quiet. Two method differences remain unmeasured: a
fresh Chrome per batch, and the puppeteer runner tracing with `v8.cpu_profiler` on. Each is a
candidate for `create10k` reading 54 ms here against 43–45 in research 73. Practical notes: npm 11
skips dependency install scripts, and the Elm entry needs a global `elm-tooling` (a shim runs it
through `npx`). The root `npm ci` fails on a peer conflict, so the server is started from
`server/`. `run.mjs`'s in-process load timer never fired under `spawnSync`, so load is now sampled
by a shell beside the runner. A quiet-machine re-run is the open item.
