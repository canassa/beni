# bench/arrays

The sequence-representation benchmarks behind research reports 38, 40, 42 and 46
(`docs/design/research/`). **`all.mjs` is the entry point**: every candidate
representation, every scenario, one batch, one table (report 46). The older
scripts reproduce the earlier reports' own figures and share its pieces.

## Setup

```sh
zig build                       # at the repository root: ../../zig-out/bin/beni
cd bench/arrays && npm ci       # esbuild, immer, mutative, immutable, mori, funkia `list`, terser
```

Node 24 comes from the repository's `flake.nix` (`direnv allow`). Chrome runs
need a Chromium: `nix develop .#browser` puts one on `PATH`, or set `CHROME`.

## `all.mjs`

### The default run: `node all.mjs`

With no arguments, `all.mjs` builds and tests if it has not, then runs **one
quick round in Node**: every candidate (the 16 of report 46 §1.2 and §11, E1tp
included; not the three checks `adaptive1024`, `adaptive-min` and `cons-raw`,
which `bench` runs), the list scenarios at 10 000 elements, the single
operations at 1 000, §15's array scenarios up to 10 000, 100 ms of warm-up per
cell, 8 workers. **It must stay under 5 minutes. Measured on 2026-09-30: 3 min
11 s of wall time (191 s) on the 16-core Ryzen 9 5950X, at a load average of
about 9.** (With the three checks and without E1tp it was 4 min 19 s.) Results
go to `results/all-quick-node.jsonl`; `node all.mjs tables quick` renders them.

### The full sweep (opt-in): `FULL=1`

```sh
node all.mjs build              # compile the three programs (below) with zig-out/bin/beni
node all.mjs test               # differential test; writes results/all-test.txt
FULL=1 node all.mjs bench 3     # Node, 3 rounds, every size -> results/all-node.jsonl (~22 min a round)
FULL=1 node all.mjs chrome 3    # headless Chrome, the same -> results/all-chrome.jsonl
node all.mjs mem                # peak and retained memory at 100 000 -> results/all-mem.jsonl
node all.mjs stack              # stack safety at 100 000, default stack -> results/all-stack.jsonl
node all.mjs size               # brotli bytes of each candidate's surface -> results/all-size.json
node all.mjs tables node        # report 46's tables -> results/all-tables-node.md
node all.mjs tables chrome      # the same from the Chrome results
node all.mjs tables-e1tp        # report 46 §11: E1tp against E1t, cons and the best other
```

`FULL=1` means the list scenarios at 1 000 / 10 000 / 100 000, the single
operations at 8 / 1 000 / 100 000, §15's scenarios at all their sizes (up to a
million grid cells), and 300 ms of warm-up. Run `build`, then `test` (it also
names the cells the non-persistent `native` candidate cannot run), then `bench`
before `chrome`, `mem` and `stack` (they skip the cells Node could not finish).
Report 46 ran one full Node round and most of a second; Chrome, `mem` and
`stack` were not run for it. Options, as environment variables:

| variable | default | meaning |
|---|---|---|
| `CANDS` | all | comma-separated candidates |
| `GROUP` | all | `arr`, `list`, `ops` (not `GROUPS`: bash owns that name) |
| `WORKERS` | 6 | parallel workers; each is pinned to a free physical core |
| `CORES` | picked | explicit cores, e.g. `2,3,4,5`; otherwise the idlest physical cores (idle > 90 % over 2 s, SMT siblings idle too) |
| `ROUND0` | 1 | the first round's number, to add rounds to an existing file |
| `FULL` | unset | `1`: the full sweep above |
| `WARM_MS` | 300 (quick: 100) | warm-up per cell (every cell starts in a fresh process) |
| `HARD_MS` | 45000 (quick: 10000) | a cell running longer is killed and recorded as `> 45 s` |
| `RESULTS` | per mode | the results file `bench`, `chrome`, `tables` and `tables-e1tp` write or read (report 46 §11: `results/e1tp-node.jsonl`) |
| `SHORT_MS`, `PREDICT_S` | 8000 (quick: 3000), 3 | a cell that could pass `PREDICT_S` a call at the next size (quadratic growth assumed) runs there under `SHORT_MS` |

**The three programs**, each compiled once and byte-identical for every
candidate; only the sibling differs:

| program | sources | core | style |
|---|---|---|---|
| `arr` | `scenarios/src/*.beni` (report 38 §15) | `core/` + `scenarios/Array.beni` | indexed code over an `Array` API; `List` stays cons cells |
| `elm` | `lists/src/*.beni` (§16) + `ops/elm/Ops.beni` (§3's single operations) | today's `core/List` | Elm-style: `::`, accumulators and `reverse` |
| `first` | `lists/first/*.beni` (§17) + `ops/first/Ops.beni` | `lists/first-core/List.beni` | array-first: `push` at the end |

`elm` and `first` have their list syntax (`[]`, `::`, `x :: rest`, tail calls
modulo cons) rewritten into calls by `lib/rewrite.js`, so a candidate decides
what they mean.

**The candidates** are `seq/*.js`, each a set of primitives over its own
representation; `seq/surface.js` turns one into every sibling the three programs
import, and derives what a candidate leaves out the same way for everyone.
`native` (a mutable array, the ceiling, not persistent), `nativecow`, `cow`,
`trie`, `hybrid1024`, `adaptive256` (ports from `ports/`), `E1` and `E1t`
(`ports/first.js`, `ports/first-tail.js`), `E1tp` (E1t with cheap prepend,
`ports/first-tail-prepend.js`, report 46 §11), `cons` (today's `List`),
`immutable`, `funkia`, `mori`, `mutative`, `immer`, `elm` (Elm's `Array`,
`seq/elm/elm-raw.js` is `elm make --optimize` output of `seq/elm/src/Main.elm`).
Two more run on `arr` only, as a check: `adaptive1024` and `adaptive-min`
(report 40's hand-minified sibling of it, `min/array.min.js`).

**How a cell is timed.** One process (or, in Chrome, one fresh browser context)
per cell, pinned to one core: warm-up, then 7 samples of at least 10 ms
(`lib/measure.js`); a call over 3 s is timed once, cold. A cell runs at its
sizes in increasing order; one that failed is not run at the next size, and
one that could be slow there runs under the short watchdog. Each round visits
the cells in a new order; a table cell is the median of the rounds' medians,
and every record carries its round, core and load average.

## The older scripts

| script | report | what |
|---|---|---|
| `mutative.mjs` | 38 §14 | Mutative, Immer and the ports, one operation at a time |
| `scenarios.mjs` | 38 §15–§17 | the array scenarios over the §15 candidates |
| `lists.mjs` | 38 §16–§17 | the list scenarios over A, B, C, D, E1, E1t |
| `lists/claim-test.mjs` | 38 §17 | the persistence test of E1t's claimable tail |
| `lists/claim-prepend-test.mjs` | 46 §11 | the persistence test of E1tp's claimable head and tail, prepends and appends mixed on shared versions |
| `min/measure.mjs` | 40 | the adaptive sibling under brotli |
| `rc/rc.mjs`, `rc/lists.mjs`, `rc/chrome.mjs` | 42 | reference counts and static in-place writes |

Their harnesses (`scenarios/harness.js`, `lists/harness.js`) are the ones
`all.mjs` runs; the timing loop (`lib/measure.js`) and the list-syntax rewrite
(`lib/rewrite.js`) are shared. Raw results of every report are in `results/`.
