# 90 — The list identity promises dropped: what the checker gains, what `browser-tea` pays

*2026-10-13. The owner decided to drop the identity promises of `core/List`'s functions that build (`language.md`
§6.8, *What an operation returns unchanged*; `backend.md` §4, *Identity*; `ownership-checker.md` §27, all
amended). This note measures it: ownership verdicts on the frozen ports and the corpus, `browser-tea` and
`browser-direct` speed on the table app and the TodoMVC-shaped sweep, and output size. The baseline is master at
`f5e33be5f`; the branch is that plus the change. Every figure is **[measured]** with §6's commands. The machine was
heavily loaded throughout (1-minute load 48–200 on 32 threads, other agents' builds), so the speed tables compare
subjects measured in one rotated batch and say nothing absolute.*

---

## 0. The answer

1. **What changed.** `map`, `indexedMap`, `filter`, `slice`, `take`, `reverse`, `sort`, `sortBy`, `sortWith`,
   `concat`, `concatMap`, `List.append` with an empty side, and `Basics.append`'s list half return a fresh list
   always, each at its old cost. The core-private `identical` and `kept` are gone (from `core/List`, its sibling,
   the emitter's operator table and the checker's asserted rows), with the `K` bit and the exempt comparison
   that existed for them, and §25.3's record rule, which existed only for `map`'s promise. The writers' no-op
   returns (`set` out of range or of the same value, `swap xs i i`, `pop []`, …) and `drop xs 0` are unchanged: a
   writer's result is its input whether it wrote or not, and a view shares its base by representation.
2. **The summaries say fresh, read off the bodies.** `filter`, `map`, `indexedMap`, `slice`, `take`, `reverse`,
   the sorts, `concat` and `concatMap` now have `res ε = fresh` alone (they had `fresh, π₁`); nothing in the
   checker asserts it.
3. **Verdicts: 12 fewer rejections, none added.** Over the 1 299 units of the sweep (§2) — the corpus outside
   `ownership/`, its `browser-tea` programs again on `browser-direct`, Sternhalma, Bike Wars, Conduit, the table
   app and the four TodoMVCs — rejected lines go from 233 of 870 to 221 of 842; no accepted line is rejected now.
   **Sternhalma: 4 of 12 rejected → 3 of 12**, on both platforms: S3, the fold over `List.filter`'s result of
   the board's cells (research 88), is accepted with no `List.copy`. **Bike Wars, Conduit, the table app and the
   four TodoMVCs: no line moves.** In the `ownership/` fixtures, T52's shape, `mirrored` and the two maps across
   types that kept their promise are accepted; in the corpus, a splice by `take` (`KeyedEnds`) and an edit inside
   `List.map`'s callback (`ListForms`).
4. **`browser-tea` pays almost nothing measurable.** Its `For` skip still fires for a list the program does not
   rebuild; it misses only where `view` builds the list again. The new `tick` operation of the FilteredFor sweep
   is exactly that case (an unrelated message while TodoMVC's `List.filter` keeps all 1 000 todos): 0.220/0.225 ms
   of script against 0.215/0.210 before, ≈ +0.01 ms, at the edge of the harness's 5 µs resolution. Every other
   operation is unchanged within its spread.
5. **`browser-direct` is not slower** anywhere measured: the table app's `update10th`, `swap`, `remove` and
   `append`, and FilteredFor's `toggle`, `filter` and `tick`, are within each other's spread before and after.
6. **Sizes go down.** The corpus's 450 programs: release gross brotli 722 387 → 717 455 B (−4 932, −0.7 %; 140
   programs smaller, 14 larger, 296 unchanged). The table app: `browser-tea --release` 5 408 → 5 365 B brotli,
   `browser-direct --release` 4 259 → 4 214 B. The empty mounted `browser-tea` page 5 805 → 5 786 B (development).
7. **Nothing stopped the work.** One finding outside it: `zig build test-browser` fails one case on this machine,
   `browser/tea/BikeWars`, because Chrome 154 serialises a style's `#222` as `rgb(34, 34, 34)` where happy-dom keeps
   `#222` — a DOM difference the change does not touch (§4).

## 1. The summaries

`beni dump --stage=ownership core/List.beni`, `res` at `ε`:

| Function | before | after |
|---|---|---|
| `map`, `indexedMap` | `~fresh₁ ~π₁` | `fresh₁` |
| `filter` | `~fresh₁ ~π₁` | `fresh₁` |
| `slice` | `fresh₁ π₁` | `fresh₁` |
| `take` | `fresh₁ ~fresh₂ ~π₁` | `fresh₁` |
| `reverse` | `fresh₁ π₁` | `fresh₁` |
| `sort` | `~fresh₁ ~fresh₂ ~π₁` | `fresh₁` |
| `sortWith` | `~fresh₁ ~fresh₂ π₁` | `fresh₁` |
| `sortBy` | `~fresh₂ π₁` | `fresh₂` |
| `concat` | `fresh₁ π₁[*]` | `fresh₁` |
| `concatMap` | `~cb₂ ~fresh₁ ~π₁[*]` | `fresh₂` |

Each loses `A` on π₁, and where the result held the input's elements only through the promise, on π₁`[*]`.
Element identity is untouched: `filter`'s result elements are still `π₁[*]`, `map`'s still `cb₂`. `append`'s
asserted row (π₁ `RAW`, `res ε = π₁`) is unchanged; its body now copies `ys` when `xs` is empty, which is what
the row's note ("`[] ++ ys` is the base, not `ys`") already claimed.

## 2. Verdicts

The sweep dumps every unit with master's binary and the branch's and matches lines by position, operation and
base: every project and loose `.beni` file under `tests/corpus` but `ownership/` (whose goldens are §3), under the
first platform it checks with, `browser-tea` programs again under `browser-direct`, and the ports.

| | before | after |
|---|--:|--:|
| units | 1 299 | 1 299 |
| demand lines | 870 | 842 |
| rejected | 233 | 221 |
| rejected → accepted | | 9 |
| rejected → gone | | 3 |
| accepted → gone | | 25 |
| accepted → rejected | | **0** |
| cause or kind changed, same verdict | | 12 |

The units that move:

| unit | platform | what moves |
|---|---|---|
| Sternhalma (research 88) | both | Main 114:13, `List.foldl board.cells`: rejected `call` (S3) → accepted `param`. 12 lines, 3 rejected |
| `browser/{direct,dom}/KeyedEnds` | both | `rows ++ List.take …` rejected `call` → accepted; the local `insertAt`, built from `take` and `drop`, no longer writes its list, so its five call lines and `update`'s entry line go |
| `browser/{direct,dom}/KeyedMoves` | both | `++ List.reverse` accepted `param` → `call`; the local `swap`'s line goes |
| `browser/direct/ReconcileMoves` | both | a construction on `List.filter` accepted `param` → `call` |
| `browser/tea/HttpResults`, `writes/ListRows` | `browser-direct` | the entry line rejected → accepted |
| `writes/ListRows`, `writes/StatsLists` | `browser-tea` (and `StatsLists` on direct) | rejected `unknown` (a list from JavaScript, through `kept`) → rejected `platform` or `payload`, the platform's own causes |
| `run/ListForms` | `node` | a construction inside `List.map` rejected `exclusive` → accepted |

**Bike Wars, Conduit, the table app and the four TodoMVCs**: no line moves on either platform.

**The rules that existed for the promises.** Two binaries were swept against the branch's: one without §25.3's
record rule, one without §16.4 item 6's type filter. Neither changed any line of the 1 299 units, and the
`ownership/` goldens do not move without the record rule. The record rule is removed (§25.3 was written for
`map`'s promise and research 85 §1.2 found it decided nothing else); the type filter stays, as `ownership-checker.md`
§27.4 says, because it is thesis §3.8's general statement and its code is the walk slice 4 is changing.

## 3. Fixtures

- `run/ListIndexedIdentity`, `run/ListIdentity` now pin the copies: 13 and 5 lines go `same` → `copied`; the
  writers' lines, `drop 0` and the element lines stay `same`. Their intent comments say why.
- `run/ListScalarView`'s `whole at the start` observed the scalar-view rule through `List.append [] all`, which
  copies now; the probe returns `all` itself when nothing came before it, and the line stays `same`.
- `ownership/Conservative`: T52's shape and `mirrored` accepted. `ownership/Differential`: `t52` accepted, the
  Lean model's copied projection. `ownership/MapAcrossTypes`: all three accepted. `ownership/Disjoint`: the
  pending-call-temporary rule kept its rejection through a helper of two arms (`forCall`), and `forFresh`, the old
  `List.reverse` shape, is accepted. Seven other goldens change summaries only.
- `emit/release/` goldens of ten programs that reach `filter`, `map` or `++` change shape; development output of
  the rest does not.

## 4. Speed

**The table app** (js-framework-benchmark's operations that reach the changed functions; `bench.mjs
--unthrottled`, research 84 §4's primary figure; `script` median ms [IQR], n = 15, one rotated batch, Chrome 154,
`--taskset=16-23`, load 48–153):

| subject | `update10th` | `swap` | `remove` | `append` |
|---|--:|--:|--:|--:|
| `browser-tea --release`, after | 1.23 [1.07–1.43] | 0.54 [0.49–0.58] | 0.47 [0.46–0.48] | 15.8 [15.6–17.4] |
| `browser-tea --release`, before | 1.22 [1.16–2.01] | 0.57 [0.51–0.61] | 0.46 [0.45–0.46] | 15.7 [15.3–16.6] |
| `browser-direct --release`, after | 0.91 [0.81–0.99] | 0.30 [0.28–0.35] | 0.28 [0.26–0.29] | 15.8 [14.8–16.5] |
| `browser-direct --release`, before | 0.90 [0.83–0.93] | 0.31 [0.29–0.35] | 0.30 [0.29–0.31] | 15.9 [15.3–16.1] |
| vanilla | 0.82 [0.74–0.88] | 0.33 [0.29–0.36] | 0.69 [0.68–0.71] | 15.8 [15.2–18.6] |

None of the table's operations relied on a builder's identity: `update10th` and `swap` change rows, `remove`
drops one. Every pair overlaps.

**FilteredFor** (`scaling.mjs --full --untraced --sweeps=filtered`, script ms, the two pages' medians of 4 samples
each; before = `--variants=old=` master's binary, built in the same run):

| op | N | tea after | tea before | direct after | direct before | Solid 2 | vanilla |
|---|--:|--:|--:|--:|--:|--:|--:|
| toggle | 100 | 0.235 / 0.220 | 0.245 / 0.220 | 0.225 / 0.255 | 0.235 / 0.240 | 0.250 / 0.255 | 0.155 / 0.175 |
| toggle | 1 000 | 0.295 / 0.285 | 0.275 / 0.305 | 0.370 / 0.370 | 0.370 / 0.355 | 0.275 / 0.260 | 0.165 / 0.160 |
| filter | 100 | 2.010 / 1.965 | 2.005 / 1.915 | 1.830 / 1.905 | 1.850 / 1.860 | 2.485 / 2.555 | 0.875 / 0.910 |
| filter | 1 000 | 16.39 / 15.51 | 15.52 / 15.70 | 15.41 / 14.69 | 14.91 / 14.78 | 18.25 / 18.59 | 7.29 / 7.42 |
| tick | 100 | 0.210 / 0.220 | 0.205 / 0.205 | 0.160 / 0.165 | 0.170 / 0.160 | 0.255 / 0.255 | 0.165 / 0.160 |
| tick | 1 000 | 0.220 / 0.225 | 0.215 / 0.210 | 0.155 / 0.165 | 0.165 / 0.165 | 0.295 / 0.300 | 0.155 / 0.155 |

`tick` is new in this sweep: a message that changes a counter no todo reads, with the filter at All, which is
TodoMVC's typing in its new-todo field. It is the one shape where `browser-tea` lost a skip: before, `List.filter`
keeping every todo returned `model.todos` itself and the `For` skipped; now it is a fresh list and the `For`
reconciles 1 000 rows whose items are all the same objects, which costs ≈ 10 µs at N = 1 000 and nothing visible
at 100. `toggle` and `filter` never skipped (the list they filter is rebuilt by the toggle, and the filter changes
what is kept). `browser-direct` does not run the derived `each` for `tick` at all (its write set does not reach
it). The absolute figures are about 4× research 70's on the same machine: the load.

The other scaling sweeps were not run: none builds a list whose identity a `For` read. `live` and `holes` change
an unrelated field without rebuilding any list, `derived`'s `List.take (List.sortBy …) 50` was a fresh list
before too, and `rows` writes its list.

**`test-browser`** (Chrome 154 through `-Dchrome`; the flake's Chromium 153 does not start on this machine, a
glibc mismatch in `libasound`): 246 of 247 pass. `browser/tea/BikeWars` fails because Chrome writes the style
`background-color: #222` back as `rgb(34, 34, 34)`, where the golden, recorded under happy-dom, has `#222`; no
other line of its transcript differs. The change does not reach style serialisation. It belongs in
`tests/corpus/README.md`'s list of known differences between the two DOMs, or in the fixture.

## 5. Size

`bench/size.mjs`, master's binary and the branch's:

| | before | after | Δ |
|---|--:|--:|--:|
| 450 programs, gross brotli (development) | 1 832 943 | 1 820 997 | −11 946 |
| 450 programs, gross brotli (`--release`) | 722 387 | 717 455 | −4 932 |
| empty page, `browser-tea` (development / release) | 5 805 / 447 | 5 786 / 447 | −19 / 0 |
| empty page, `browser-direct` | 1 604 / 316 | 1 582 / 316 | −22 / 0 |
| table app, `browser-tea --release` | 5 408 | 5 365 | −43 |
| table app, `browser-direct --release` | 4 259 | 4 214 | −45 |

`map` loses its comparison and `kept`; `filter` loses `filterFirst`; `concat` loses `firstFrom`; the early returns
go. Fourteen programs grow by a few bytes, where an early return was cheaper than reaching the builder loop.

## 6. Commands

```sh
git checkout f5e33be5f && zig build && cp zig-out/bin/beni zig-out/base/beni   # master's binary
# the branch: zig build gates builds zig-out/safe/bin/beni
node sweep.mjs zig-out/base/beni zig-out/base/beni-new out.json   # §2: dump both, match lines (kept out of the tree)
beni dump --stage=ownership --platform=browser-tea src            # examples/sternhalma, and browser-direct
beni dump --stage=ownership core/List.beni                        # §1
node bench/ui/build.mjs (master's beni, out dirs renamed old-*; then the branch's), out/extra-subjects.json naming
  old-beni-release and old-beni-direct-release
CHROME=google-chrome node bench/ui/bench.mjs --subjects=beni-release,old-beni-release,beni-direct-release,\
  old-beni-direct-release,vanillajs --benchmarks=03_update10th1k_x16,05_swap1k,06_remove-one-1k,\
  08_create1k-after1k_x2 --n=15 --unthrottled --taskset=16-23 --out=results/2026-10-13-identity-table-rate1.json
CHROME=google-chrome node bench/ui/scaling.mjs --full --untraced --sweeps=filtered --variants=old=../../zig-out/base/beni \
  --subjects=beni-release,beni-old-release,beni-direct-release,beni-old-direct-release,vanillajs,solid2 \
  --taskset=16-23 --out=results/2026-10-13-identity-filtered-untraced.json
node bench/size.mjs --beni=zig-out/base/beni; node bench/size.mjs --beni=zig-out/safe/bin/beni
zig build test-browser -Dchrome=/run/current-system/sw/bin/google-chrome
```

`bench.mjs --unthrottled` and the variants' release and `browser-direct` builds in `scaling.mjs` are added by this
change, as is FilteredFor's `tick`.
