# The state of the compiler — 2026-09-18 evening

One page for an owner offline since the morning: where `master` (`8be8e17`)
stands against its budgets, and what the static-dispatch adoption costs **now**
rather than at 13:05, when
[`research/19-static-dispatch-spike-results.md`](../docs/design/research/19-static-dispatch-spike-results.md)
priced it. Taken this evening, one machine, one sitting; raw instrument lines
are quoted verbatim per section and every table derives from them alone. No
verdicts; the number that most deserves attention is named at the end of §8.

## 0. Against the budgets

`fast-compiler.md` §2 and `backend.md` §13 are the two tables with targets.

| Budget | Target | Measured today | Margin |
|---|---|---|---|
| Type-checking throughput, cold, **per core** | **> 250 k LOC/s** | **1 285 k – 1 322 k LOC/s** (§2) | **5.1–5.3×** |
| Cold full build, 100 k LOC, incl. core | **< 800 ms** | **109 ms** dev / **111 ms** release, default jobs; **196 / 199 ms** at `--jobs=1` (§3) | **7.3×** (4.0× on one core) |
| Emit throughput | **> 5 MB/s of JS** | **59.2 – 61.5 MB/s**, 2.09 – 2.17 M JS lines/s (§2) | **12×** |
| Output size — "Elm's TodoMVC at 9 KB compressed is the number to beat" | ~9 KB brotli | largest program in the tree **7 513 B** brotli release; median **3 828 B**; floor **789 B** (§4) | met on every program measured |
| Own output vs esbuild `--minify`, within ~10 % | ≤ 1.1× | **not measured** — no esbuild comparison exists (§9) | — |

| | Today | Morning (C1, report 19 §8) | C0 (`c870e9a`) |
|---|---:|---:|---:|
| ReleaseFast binary | **17 847 592 B** | 16 751 800 B | 13 253 080 B |
| cold-local ReleaseFast build | **69.6 s** | 64.1 s | 46.9 s |
| `zig build test` cold / warm | **8.6 / 7.4 s** | 8.79 / 7.00 s | 8.55 / 6.97 s |
| `zig build test-blackbox` | **78.4 / 78.7 s** | 50.5 s | 31.4 s |
| floor (empty program) raw / brotli | **2 147 / 833 B** dev · **1 880 / 789 B** release | 68 791 / 13 838 B | 65 214 / 12 932 B |
| `bench/corpus` raw / brotli † | **126 436 / 21 840 B** dev · **55 593 / 15 017 B** release | 121 965 / 22 507 B | 109 053 / 20 423 B |

† today's line measures **9** modules where both earlier lines measure **7** (§4).

## 1. Method

**Machine.** `dagon`: AMD Ryzen 9 5950X, 16C/32T, 31 GiB, Linux 6.12.110 NixOS,
Zig 0.16.0, Node v24.19.0 from the flake — "machine 2" of
`plans/static-dispatch-spike-results.md`, so every morning/evening comparison
is within one machine. It is **not** the N100 of `bench/README.md`'s older
entries.

**Binaries.** **A** = `../beni-s1/zig-out/bin/beni` at `c870e9a`, ReleaseFast,
`stat` **13 253 080 B** — `master` before static dispatch and before today,
unmodified. (Report 19 §8's table prints `13 253 088` where its §1.2 prints
`13 253 080`; `stat` says the latter.) **B** = `8be8e17`, ReleaseFast, to a
scratch prefix, never into the repo's `zig-out`: **17 847 592 B** — and
**17 848 584 B** for the same commit in a throwaway worktree, a 992-byte
difference not explained (report 19 §16 records 40- and 8-byte versions).

**Discipline.** `uptime` verbatim before every instrument; the 1-minute load
stayed between **0.04 and 1.05** for every recorded run and nothing was
discarded for load. No instrument ran while a build ran. Every before/after pair
is interleaved ABBA in one machine state. `~/.cache/zig` never cleared.

**What this session changed.** `bench/runtime/c0/*.beni` and `c1/*.beni`,
**comment text only**, in the five pairs whose headers said the tail-call loop
"has not landed" — it landed in `bbfc869`. The block split (4 × 500 and the
like) is **left exactly as it was**: vestigial for any compiler at or after
`bbfc869`, still mandatory for the C0 baseline binary, and its `-- ops:` counts
and checksums are cited throughout the results file. All six checksums were
re-verified and are unchanged. Also `bench/README.md`, an append to the results
file, and this page. No `src/`, no `core/`, no test, no golden.

**What is comparable.** (1) §2 is one program through two checkers — A checks
635 modules, B 633 — and, new tonight, the generated *user* corpus is no longer
byte-identical either: A writes 1 835 619 bytes, B 1 835 956 (+337), because
`bench/gen.zig` now respects the `let`-order rule of `3c8fbf8` and picks a
different in-scope local in 323 of 624 files. **Token count (302 615) and AST
node count (221 576) are identical on both sides**, so the corpora are the same
shape to 0.018 %. (2) §4 measures two program sets, two sources and two root
rules: A has 35 programs, `main`-only roots, no elimination; B has 108,
`--library` roots for `bench/corpus`, DCE always on; and the 35 shared *names*
were rewritten by the C1 corpus change. (3) §4's A column comes from A's own
harness — HEAD's `bench/size.mjs` passes `--library`, which A rejects, and
HEAD's corpus does not compile on A — so A ran `node bench/size.mjs` inside
`../beni-s1`, what report 19 §5 did, reproducing its C0 column to the byte.
(4) §5 cannot run four variants on six programs: `c0/R1DictString` and
`c0/R2DictRecord` no longer compile on B (`Dict.empty` is a constant now), so
"same source, two compilers" exists for R3–R6 only.

## 2. M1a — what the day cost code that uses none of it

`zig build bench -- --generate=100000 --iterations=5`, ABBA, A from
`../beni-s1`, B from the main checkout.

```
 22:25:51 up 11:28,  3 users,  load average: 0.57, 1.23, 1.66
A1 bench: generated 624 files, 100159 lines, 1835619 bytes (plain) under .zig-cache/bench-gen
A1 {"phase":"check","modules":635,"lines":100159,"unifications":231352,"generalisations":101320,"instantiations":55228,"obligations":3151,"constraints_created":0,"constraints_merged":0,"constraints_deferred":0,"constraints_discharged":0,"constraints_promoted":0,"diagnostics":0,"ms":62.29,"loc_per_s":1607954,"cold_check_ms":95.1}
A1 {"phase":"emit","modules":635,"js_bytes":3075595,"nodes":254951,"lines":103669,"ms":28.41,"mb_per_s":103.2,"loc_per_s":3648393}
A1 {"phase":"total","files":624,"bytes":1835619,"tokens":302615,"nodes":221576,"insts":205097,"ms":117.9,"mb_per_s":14.8,"loc_per_s":849314}
B1 bench: generated 624 files, 100159 lines, 1835956 bytes (plain) under .zig-cache/bench-gen
B1 {"phase":"check","modules":633,"lines":100159,"unifications":228342,"generalisations":103891,"instantiations":52375,"obligations":3452,"constraints_created":262,"constraints_merged":2,"constraints_deferred":442,"constraints_discharged":2716,"constraints_promoted":1,"diagnostics":0,"ms":77.95,"loc_per_s":1284974,"cold_check_ms":109.5}
B1 {"phase":"emit","modules":633,"js_bytes":3086683,"nodes":320961,"lines":103725,"ms":48.15,"mb_per_s":61.1,"loc_per_s":2154324}
B1 {"phase":"total","files":624,"bytes":1835956,"tokens":302615,"nodes":221576,"insts":202303,"ms":151.7,"mb_per_s":11.5,"loc_per_s":660243}
A1 lex 7.2 · parse 5.7 · lower 7.2 · resolve 4.33     A2 lex 6.8 · parse 5.7 · lower 7.0 · resolve 3.51 · check 61.98 · emit 27.84 · total 115.8
B1 lex 7.3 · parse 5.6 · lower 7.3 · resolve 2.66     B2 lex 6.7 · parse 5.7 · lower 7.4 · resolve 4.98 · check 76.73 · emit 49.70 · total 154.2
 22:25:57 up 11:28,  3 users,  load average: 0.71, 1.24, 1.66
B alone x3, load 0.55 -> 0.59:  check 77.38 / 75.75 / 77.81 · emit 47.83 / 48.14 / 49.20 · total 149.9 / 153.1 / 153.5
```

| phase | A (r1, r2) ms | B (r1, r2) ms | B ÷ A | morning (report 19 §2.1) |
|---|---:|---:|---:|---:|
| lex · parse · lower (resolve varies) | see the block above | | **0.94–1.03×** | 0.98–1.02× |
| **check** | **62.29, 61.98** | **77.95, 76.73** | **1.245×** | 1.203× |
| **emit** | **28.41, 27.84** | **48.15, 49.70** | **1.740×** | 1.480× |
| **total** | **117.9, 115.8** | **151.7, 154.2** | **1.309×** | 1.218× |
| `js_bytes` | 3 075 595 | **3 086 683** | **+0.36 %** | **+25.8 %** |

Spread inside B over five runs: check 2.9 %, emit 3.9 %, total 2.9 % — a fifth
to a tenth of every gap above.
**Reading.** `check` costs **24.5 %** more than C0 on a corpus that writes no
`where` clause and no dot-call, against **20.3 %** this morning: the check-time
tax did not go away and moved 4 points the wrong way. It is still not
unification — B does 3 010 fewer unifications and 2 853 fewer instantiations
than A — but the obligation bookkeeping report 19 §2.1 named, plus today's three
new checker passes (`Cycles`, irrefutable-position usefulness, `let` order),
which this instrument cannot separate. `emit` and `js_bytes` moved in opposite
directions: output grew 25.8 % this morning and **0.36 %** tonight, while emit
*time* went 1.48× → **1.74×** C0's on 26 % more `JsIr` nodes (320 961 against
254 951) for the same bytes — decision trees, the tail-call loop and the
dispatch shape build a bigger IR and then print it away. At 61 MB/s that is 12×
`backend.md` §13's target: a trend, not a problem. It does **not** say this is
one binary on one corpus (§1).

## 3. The cold 100 k-line build against the 800 ms budget

The generated corpus declares no `main`, so it is built with `--library` (every
export a root); copied out of `.zig-cache` first. Three runs each.

```
 22:26:43 up 11:29,  3 users,  load average: 0.45, 1.09, 1.59
dev-default  real 0m0.109s / 0m0.108s / 0m0.109s      rel-default  real 0m0.110s / 0m0.111s / 0m0.112s
dev-j1       real 0m0.195s / 0m0.196s / 0m0.199s      rel-j1       real 0m0.198s / 0m0.200s / 0m0.200s
--self-profile, ms, summed per event:
dev  --jobs=1  check 70.66 | emit 59.85 | solve 35.85 | constrain 15.47 | lower 14.37 | lex 12.40 | parse 10.59 | read 5.57 | exhaustive 3.32 | resolve 3.25 | merge_interners 1.42 | eliminate 1.20 | enumerate 0.74 | graph 0.71 | types 0.71
rel  --jobs=1  check 71.36 | emit 61.25 | solve 36.27 | constrain 15.56 | lower 14.63 | lex 12.13 | parse 10.65 | read 5.56 | exhaustive 3.37 | resolve 3.33 | merge_interners 1.40 | eliminate 1.31 | enumerate 0.74 | graph 0.71 | types 0.52
dev  default   check 262.40 | lex 63.41 | solve 63.03 | emit 58.88 | lower 54.98 | constrain 49.83 | parse 47.98 | read 43.34 | exhaustive 9.09 | resolve 3.17 | eliminate 1.27
```

| configuration | wall | vs 800 ms | files | bytes written |
|---|---:|---:|---:|---:|
| dev, default jobs (32) | **109 ms** | **7.3× under** | 629 | 1 616 493 |
| dev, `--jobs=1` | **196 ms** | 4.1× under | 629 | 1 616 493 |
| `--release`, default | **111 ms** | 7.2× under | 629 | 734 931 |
| `--release`, `--jobs=1` | **199 ms** | 4.0× under | 629 | 734 931 |

At `--jobs=1` the profile events are wall-like; at default jobs they are summed
worker CPU, which is why they exceed the 109 ms wall.

**Reading.** The budget the project aims at is met with **7.3× of headroom**,
and **4× on a single core**. Two prices from today are visible and both small:
reachability elimination costs **1.20 ms of a 196 ms build** and removes 48 % of
the bytes (3 086 683 emitted → 1 616 493 written); `--release` costs **1.4 ms of
emit, 2.3 %**, for a further 55 % off. Parallel scaling is 1.8× — 100 ms of work
with a serial tail, not a scheduler finding. It does **not** price a real root
rule (`--library` is the most generous), and with no daemon everything is cold.

## 4. Output size

`node bench/size.mjs` on B (dev **and** `--release` in one run, post-DCE), and
the same script inside `../beni-s1` for A. Load 0.25 and 0.24. These are byte
counts, not timings; what makes them trustworthy is A reproducing report 19's
C0 column exactly, not interleaving.

```
 22:27:22 up 11:29,  3 users,  load average: 0.25, 0.97, 1.53   (B)     22:28:13 up 11:30, load average: 0.24, 0.85, 1.45   (A)
A {"floor":true,"entry":"Empty","files":21,"raw_bytes":65214,"gzip_bytes":15410,"brotli_bytes":12932,"derived_bytes":0,"derived_functions":0}
A {"program":"bench/corpus",…,"modules_measured":7,"modules_excluded":["Data/Parser.beni","ExprParser.beni","JsonCodecs.beni","NotesApp.beni"],"files":28,"raw_bytes":109053,"gzip_bytes":24085,"brotli_bytes":20423,…}
A {"program":"tests/corpus/run/Dictionaries.beni","files":21,"raw_bytes":66145,"gzip_bytes":15635,"brotli_bytes":13114,…,"net_raw_bytes":931}
A {"total":true,"programs":35,"files":742,…,"gross_raw_bytes":2361110,"gross_gzip_bytes":555937,"gross_brotli_bytes":467251,"derived_bytes":0}
B {"floor":true,"entry":"Empty","files":5,"raw_bytes":2147,"gzip_bytes":1013,"brotli_bytes":833,"release_files":5,"release_raw_bytes":1880,"release_gzip_bytes":950,"release_brotli_bytes":789,"derived_bytes":0,"derived_functions":0,…}
B {"program":"bench/corpus",…,"roots":"library","modules_measured":9,"modules_excluded":["JsonCodecs.beni","NotesApp.beni"],"files":25,"raw_bytes":126436,"gzip_bytes":25659,"brotli_bytes":21840,"derived_bytes":14454,"derived_functions":60,"eq_functions":24,"eq_bytes":5113,"compare_functions":20,"compare_bytes":8075,"order_tables":16,"order_bytes":1266,"release_raw_bytes":55593,"release_gzip_bytes":17144,"release_brotli_bytes":15017,…}
B {"program":"tests/corpus/run/Dictionaries.beni","roots":"main","files":13,"raw_bytes":31495,"gzip_bytes":8237,"brotli_bytes":7008,"derived_bytes":0,…,"release_raw_bytes":19836,"release_gzip_bytes":6773,"release_brotli_bytes":5860,…}
B {"total":true,"programs":108,"files":1077,"raw_bytes":1462115,…,"gross_raw_bytes":1691844,"gross_gzip_bytes":548294,"gross_brotli_bytes":473235,"release_raw_bytes":1361289,"release_gzip_bytes":503718,"release_brotli_bytes":435758,"derived_bytes":24787,"derived_functions":146,"eq_functions":73,"eq_bytes":10377,"compare_functions":50,"compare_bytes":12734,"order_tables":23,"order_bytes":1676}
```

The C1-morning column is `results:926` (floor) and `results:2046`
(`bench/corpus`), i.e. report 19 §5.1 and §5.2.

| | C0 (A) | C1, morning | **HEAD dev** | **HEAD release** | dev ÷ C0 |
|---|---:|---:|---:|---:|---:|
| **floor** raw · gzip · brotli · files | 65 214 · 15 410 · 12 932 · 21 | 68 791 · 16 399 · 13 838 · 19 | **2 147 · 1 013 · 833 · 5** | **1 880 · 950 · 789 · 5** | **0.033× · 0.066× · 0.064×** |
| **`run/Dictionaries`** raw · brotli | 66 145 · 13 114 | — | **31 495 · 7 008** | **19 836 · 5 860** | 0.476× · 0.534× |
| **`bench/corpus`** raw · brotli † | 109 053 · 20 423 | 121 965 · 22 507 | **126 436 · 21 840** | **55 593 · 15 017** | 1.159× · 1.069× |
| `bench/corpus` derived bytes / fns | 0 / 0 | 11 659 / 59 | **14 454 / 60** (240.9 B each) | n/a ‡ | — |
| **the 35 programs on both sides**, gross raw · gzip · brotli | 2 361 110 · 555 937 · 467 251 | — | **636 142 · 200 561 · 172 942** | **495 314 · 181 236 · 156 920** | **0.269× · 0.361× · 0.370×** |
| median per-program raw ratio | — | — | **0.215×** | — | — |

† `bench/corpus` is the one row that grew, and the one row whose *input* grew:
tonight measures 9 modules, both earlier lines 7 (`Data/Parser` and `ExprParser`
did not build then). Not a like-for-like row. ‡ the derived split is dev-only by
construction — it reads declarations by name and `--release` renames them.

`--release` ÷ dev, gross over all 108 programs: raw **0.805×**, gzip **0.919×**,
brotli **0.921×**. Per-program release brotli over the 107 `run/` fixtures: min
850, median 3 828, p90 5 320, max 7 513.

**Reading.** Every size figure in report 19 carried "an upper bound because
there is no DCE". The bound is collected: an empty program ships **2 147 bytes
instead of 65 214**, and the 35 programs on both sides ship **27 % of C0's raw
bytes and 37 % of its brotli**. The adoption's +5.5 % floor and +11.8 % corpus
are dead as headline numbers. One trap: on the `{"total":…}` line
`raw_bytes`/`gzip_bytes`/`brotli_bytes` use the floor-counted-once arithmetic
while `release_*` are plain **gross** sums, so those two fields say release is
*larger*; `gross_*` against `release_*` is the honest pair, used above. It does
**not** say the 35 shared names are the same source (§1), nor that brotli over a
concatenation is what a chunked build ships — chunking has not landed.

## 5. Runtime of the emitted JavaScript

`node bench/runtime.mjs --runs=20`, four variants interleaved over two rounds
(A-c0, B-c1 dev, B-c1 release, B-c0; then reversed). **Every program printed
the same checksum in every variant and every round** — `60000 288894`,
`60000 18600000`, `4000 499313`, `400 20000 200 0 6` (fourth field
`nearMisses` = 0), `5000000`, `1352000` — so no row here is a wrong answer
arriving quickly.

```
 22:29:13 up 11:31,  3 users,  load average: 0.09, 0.69, 1.36
r1 A-c0 {"program":"R1DictString","variant":"c0","runs":20,"ops":120000,"floor_ms":27.49,"best_ms":213.31,"median_ms":226.99,"ns_per_op":1548.5,"checksum":"60000 288894"}
r1 A-c0 {"program":"R4Equality","variant":"c0","runs":20,"ops":220200,"floor_ms":27.56,"best_ms":123.18,"median_ms":127.96,"ns_per_op":434.2,"checksum":"400 20000 200 0 6"}
r1 B-c0 {"program":"R4Equality","variant":"c0","release":false,"runs":20,"ops":220200,"floor_ms":27.52,"best_ms":39.69,"median_ms":43.63,"ns_per_op":55.3,"checksum":"400 20000 200 0 6"}
r1 B-c1 {"program":"R5EvidenceForwarding","variant":"c1","release":false,"runs":20,"ops":10000000,"floor_ms":27.83,"best_ms":52.59,"median_ms":55.28,"ns_per_op":2.5,"checksum":"5000000"}
r1 B-c0 bench/runtime.mjs: R1DictString did not build / R2DictRecord did not build  (`Dict.empty` is not a function on HEAD)
 22:31:18 up 11:33,  3 users,  load average: 0.92, 0.83, 1.32
R3 alone, --runs=30, three interleaved rounds:   22:38:40 up 11:41, load average: 0.04, 0.27, 0.85
A-c0 748.1 · 762.4 · 773.4 (mean 761.3)   B-c0 771.9 · 766.4 · 788.3 (mean 775.5)   B-c1 804.3 · 802.3 · 817.6 (mean 808.1)
```

ns/op; the "C0 source" column is one file through both compilers, the pure
compiler effect of the day's work.
| program | A = C0 (r1, r2) | B, C1 dev | B, C1 `--release` | B on the C0 source | C1 ÷ A |
|---|---|---|---|---|---:|
| R1 `Dict` / `String` keys | 1 548.5, 1 689.7 | 1 637.8, 1 636.6 | 1 637.8, 1 672.3 | does not build | **1.01×** |
| R2 `Dict` / record key | 634.0, 694.5 | 607.6, 660.7 | 634.3, 637.8 | does not build | **0.95×** |
| R3 `List.sort` ×3 | 765.7, 822.1 | 822.3, 856.2 | 831.2, 845.8 | 806.3, 832.1 | **1.06×** |
| **R4 equality** | 434.2, 476.8 | — (no C1 program) | — | **55.3, 51.2** | **0.117× — 8.6× faster** |
| **R5 evidence forwarding** | 7.7, 8.3 | **2.5, 2.7** | 2.6, 2.6 | 7.4, 7.7 | **0.325× — 3.1× faster** |
| **R6 megamorphic** | 28.3, 30.4 | **23.6, 24.4** | 24.4, 24.7 | 25.6, 25.3 | **0.818× — 1.22× faster** |

`--cpu-prof`, top self-time frames, fresh directory per run:

```
A-c0 R3Sorting   sample 104.0 ms: codePoints 20.1 (19.3%) · List$mergeWithHelp 19.3 (18.5%) · (program) 8.7 · List$splitHalfHelp 8.1 · (GC) 7.4 (7.1%) · cons 6.3 · (anon List.mjs:219) 5.3 · compare 4.0
B-c0 R3Sorting   sample 110.3 ms: List$sortWith 23.3 (21.1%) · (GC) 18.5 (16.7%) · codePoints 14.8 · cons 7.8 · (program) 7.7 · compare 3.6 · (anon List.mjs:33) 3.4 · List$foldl 3.2
B-c1 R3Sorting   sample 115.5 ms: List$sortWith 19.0 (16.4%) · codePoints 18.0 · cons 15.4 (13.3%) · (GC) 13.7 (11.9%) · (program) 8.6 · List$mergeWithHelp 8.6 · compare 6.3
A-c0 R1DictString sample 215.6 ms: codePoints 108.4 (50.3%) · (GC) 29.3 · Dict$balance 17.2 · Dict$getHelp 15.9 · Dict$insertHelp 7.3
B-c1 R1DictString sample 213.8 ms: codePoints 103.7 (48.5%) · (GC) 28.9 · Dict$balance 13.8 · Dict$insertHelp 13.8 · (anon R1DictString.mjs:11) 11.6
```

**Reading.** Report 19 §6's shape survives and two rows improved: R4 is **8.6×**
faster than C0 where the morning read 7.2×; R5 holds at 3.1×, R6 at 1.22×; R1
and R2 stay inside the noise. **`--release` costs nothing measurable at run
time** on any of the five programs it can build — `backend.md` §9's own
acceptance condition for the optimiser, met. **R3 got worse, and by less than
the commit that caused it said.** `128002b` recorded its price as "R3Sorting is
18 % slower (783.9 → 928.2 ns/op, interleaved)"; at HEAD, 30 runs, load 0.04,
R3's C1 side reads **808.1**, and the same C0 source through both compilers
costs **+1.9 %** (761.3 → 775.5), the C1 program +6.1 % over C0. The profile
says where it goes: on identical source, GC moves **7.4 → 18.5 ms** and `cons`
6.3 → 15.4 ms on the C1 program — decorate-sort-undecorate allocating a pair per
element — while the merge loop was absorbed, `List$mergeWithHelp` at 18.5 % of
C0's sample becoming `List$sortWith` at 21.1 % of B's. R1 is half
`String.codePoints` on both sides: a string-hashing benchmark holding a `Dict`.

## 6. The checker's pathological shapes

### 6.1 The unannotated constraint chain

`zig build bench -- --pathological=constraint-chain=<n> --iterations=5`, ABBA
per n; peak RSS from a separate `check --jobs=1` run.

```
 22:32:14 up 11:34,  3 users,  load average: 0.37, 0.69, 1.24
n=1000 A {"phase":"check","modules":12,"lines":3008,"unifications":20216,"generalisations":1509367,"instantiations":5622,"obligations":3,"constraints_created":0,…,"diagnostics":0,"ms":241.81,"loc_per_s":12439,"cold_check_ms":244.1}
n=1000 B {"phase":"check","modules":10,"lines":3008,"unifications":16139,"generalisations":71878,"instantiations":5563,"obligations":32549,"constraints_created":1008,"constraints_merged":984,"constraints_deferred":32549,"constraints_discharged":39,"constraints_promoted":31525,"diagnostics":15,"ms":32.76,"loc_per_s":91826,"cold_check_ms":35.0}
n=3000 A {"phase":"check",…,"generalisations":1607447,"obligations":3,…,"diagnostics":1,"ms":256.83,…}
n=3000 B {"phase":"check",…,"generalisations":214328,"obligations":98774,"constraints_created":3008,"constraints_merged":2953,"constraints_deferred":98774,"constraints_discharged":39,"constraints_promoted":95735,"diagnostics":46,"ms":99.19,…}
second halves: A 244.47 / 254.12 · B 33.49 / 97.99                  22:32:25 up 11:34, load average: 0.46, 0.70, 1.24
n=1000 A maxrss_kb 268212 wall 0.25s exit 0   |  n=1000 B maxrss_kb 34920 wall 0.05s exit 1
n=3000 A maxrss_kb 256324 wall 0.25s exit 1   |  n=3000 B maxrss_kb 94540 wall 0.14s exit 1
n=1000 B diagnostics total=1000 {"ambiguous_method_receiver":985,"too_many_inferred_constraints":15}
n=3000 B diagnostics total=3000 {"ambiguous_method_receiver":2954,"too_many_inferred_constraints":46}
n=1000 A total=0    n=3000 A total=1 {"unknown_field":1}
```

| n | A `check` ms | **B `check` ms** | B, morning (report 19 §3) | **B ÷ B morning** | B `obligations` | morning `constraints_promoted` | A RSS | **B RSS** | B RSS morning |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 000 | 241.81, 244.47 | **32.76, 33.49** | 441.02, 437.38 | **13.3× faster** | **32 549** | 500 500 | 268 MB | **34.9 MB** | 411 MB |
| 3 000 | 256.83 †, 254.12 † | **99.19, 97.99** | 4 442.51, 4 477.26 | **44.8× faster** | **98 774** | 4 501 500 | 256 MB † | **94.5 MB** | 3 754 MB |

† A refuses the chain past ≈64 links with one `unknown_field`, so its ~250 ms
and ~256 MB are the cost of a refusal — report 19 §3's own caveat.

**Reading.** Report 19's headline here was "**n² obligations**" and "3.6 GB of
resident memory". **The n² is gone**: `obligations` reads 32 549 at n = 1 000
and 98 774 at n = 3 000 — 3.03× for 3× the input, linear — where the morning
read n(n+1)/2 to the unit. That is the 64-constraint cap of `9074538`, and it is
not free: the compiler now **refuses** 15 declarations at n = 1 000 and 46 at
n = 3 000 with `too_many_inferred_constraints`, and exits 1. **The quadratic was
converted into a diagnostic.** A chain that cost 4.4 s and 3.7 GB this morning
costs 99 ms and 94 MB, and part of it is no longer checked. The other number is
`ambiguous_method_receiver`, now default-on, firing **985 times on a 1 000-link
chain** — §7 says what it finds in real code.

### 6.2 Flat and pair-keyed 2 000-row `case`

Generated into scratch: `case n of` with 2 000 `Int`-literal branches plus a
wildcard, and `case ( row, col ) of` with 2 000 pair branches (a 40 × 50 grid)
plus a wildcard; 6 005 lines each.

```
 22:33:38 up 11:35,  3 users,  load average: 0.13, 0.54, 1.14
B flat maxrss_kb=5376 / 5632 / 5632 exit=0     A flat maxrss_kb=4464 exit=0
B pair maxrss_kb=6576 / 6464 / 6384 exit=0     A pair maxrss_kb=7672 exit=0
20 sequential runs: A flat real 0m0.137s · B flat 0m0.147s · A pair 0m0.197s · B pair 0m0.187s
self-profile, B, --jobs=1:  flat  check 2.69 | solve 1.01 | lower 0.65 | constrain 0.64 | lex 0.62 | exhaustive 0.59
                            pair  check 4.09 | solve 1.33 | constrain 1.30 | exhaustive 0.96 | lower 0.83 | lex 0.76
```

Derived: 2 000 rows check end to end in **7.4 ms** flat and **9.4 ms**
pair-keyed at 5.5 and 6.5 MB, of which `exhaustive` itself is **0.59 ms** and
**0.96 ms**.

**Reading.** A 2 000-row lookup table costs **under a millisecond of
exhaustiveness** on both shapes — what `992ab59` and `889caae` bought, against
~1.05·n² and ~2n² steps before them. A's column is **not** evidence that
`master` handled these: A has no `--pattern-budget` flag at all, and exits 0
because before `f21ac4c` exceeding the budget was silent rather than an error.
The two exit 0s do not assert the same thing.

## 7. Interface churn, and the annotation debt

`sh bench/churn.sh` on B, both corpora, plus a count of the now-default
`ambiguous_method_receiver` warning (taken by *building* each corpus, since
`check` alone cannot resolve `Node`).

```
 22:34:08 up 11:36,  3 users,  load average: 0.14, 0.50, 1.10          22:34:32 up 11:36, load average: 0.38, 0.54, 1.10
bench/corpus (JsonCodecs.beni, NotesApp.beni excluded; tree restored: yes)   103 decls
  E1 annotated 0/20 · E1 unannotated 0/19 · E2 annotated 0/1 · E2 unannotated 0/1
  E3 annotated 0/70 · E3 unannotated 29/68 · E3poly annotated 0/0 · E3poly unannotated 4/4
core (tree restored: yes)                                                   140 decls
  E1 annotated 0/15 · E1 unannotated 0/15 · E2 annotated 0/7 · E2 unannotated 0/7
  E3 annotated 0/74 · E3 unannotated 50/90 · E3poly annotated 0/0 · E3poly unannotated 12/12
 22:34:56 up 11:37,  3 users,  load average: 0.25, 0.49, 1.07
bench/corpus, 9 modules behind a synthesised library entry:  total=0
tests/corpus/run, 107 programs built one at a time:          total=0
core, `check --core`:                                        total=0
```

| corpus | edit | variant | C0 (report 19 §4) | C1, morning | **HEAD** |
|---|---|---|---:|---:|---:|
| `bench/corpus` | E3 | annotated | 0/52 | 0/70 | **0/70** |
| | **E3** | **unannotated** | **5/52 (9.6 %)** | **29/68 (42.6 %)** | **29/68 (42.6 %)** |
| | E3poly | unannotated | 4/4 | 4/4 | **4/4** |
| `core` | E3 | annotated | 0/88 | 0/74 | **0/74** |
| | **E3** | **unannotated** | **8/94 (8.5 %)** | **50/90 (55.6 %)** | **50/90 (55.6 %)** |
| | E3poly | unannotated | 14/14 | 12/12 | **12/12** |

**Reading.** Churn did not move: every cell of both tables is byte-identical to
the morning's C1 run, although `core` gained two `pub` declarations since (140
against 138). The objection report 18 §2.3 raised stands exactly where report 19
left it — 0 interface changes for every annotated declaration in every edit class
on both corpora, 4.4–6.5× worse than C0 on unannotated `pub` ones. The new
number is the annotation debt that translates to, and it is **zero**: the warning
fires 985 times on a synthetic chain and **not once** in `core`,
`bench/corpus` or any of the 107 `run/` fixtures — evidence about this codebase,
not about codebases, since both trees were written under the rule.

## 8. The adoption's bill, re-priced

Report 19 §15 option (b), "adopt the whole spike", listed a measured-cost
column. Every entry restated beside tonight's number.

| Report 19 §15 (b), 13:05 | Tonight | |
|---|---|---|
| `check` **+20.3 %** on code that never uses it (§2.1) | **+24.5 %** (§2) | **worse by 4 points**, and now carries three new checker passes too |
| `emit` **1.48×** (§2.1) | **1.74×** (§2) | **worse** — 26 % more `JsIr` nodes for the same bytes |
| floor **+5.5 %** raw (§5.1) | floor is **0.033× of C0**, 65 214 → 2 147 B (§4) | **superseded** — DCE collected the "upper bound" |
| `bench/corpus` **+11.8 %** (§5.2) | +15.9 % raw, over **9 modules against 7** (§4) | **not comparable**; the 35 shared programs ship **0.269×** C0's raw |
| ~198 B per derived function (§5.2) | 14 454 B over 60 = **240.9 B** (§4) | worse per function, far better in total |
| unannotated `pub` churn **4.4–6.5× worse** (§4) | **unchanged, cell for cell** (§7) | unchanged; real-corpus warning count **0** |
| **n² obligations** on an unannotated chain (§3) | **linear** — 32 549 and 98 774 (§6.1) | **fixed, by refusing**: 15 and 46 `too_many_inferred_constraints` |
| compiler **+8 992 lines of `src/`** (§8) | **+16 871 −884** over 43 files, `c870e9a..HEAD` | the day roughly doubled it; `src/js` alone +7 442 −480 |
| cold build **1.37×** (§8) | 46.9 → **69.6 s** = **1.48×** | worse |
| binary **1.264×** (§8) | 13 253 080 → **17 847 592 B** = **1.347×** | worse |
| black-box gate **1.61×** (§8) | 31.4 → **78.4 s** = **2.50×** | **much worse** — 619 `.beni` fixtures, 498 corpus files changed since `c870e9a` |
| R4 7.2× · R5 3.2× · R6 1.28× faster (§6) | **8.6× · 3.1× · 1.22×** (§5) | held; R4 improved |
| — (no report-19 row) | R3 **+6.1 %** slower than C0, +1.9 % from the compiler alone (§5) | new cost, from `128002b` |

**What got better.** Output size, on every axis: the "upper bound with no DCE"
caveat governing the whole of report 19 §5 is retired and the numbers under it
are 3–30× *smaller* than C0's rather than 5–12 % larger; the n² obligation
blow-up is linear; R4 is faster still; churn is where it was and the warning
finds nothing to warn about here. **What got worse.** The compiler: 1.35× C0's
binary, 1.48× the build, a black-box gate at **2.50×**, emit at 1.74× per byte
produced, and R3 costing 6 % more than C0 at run time.

**What is unchanged — measured, not assumed.** The check-time tax did not go
away: **24.5 %**, taken tonight ABBA on 100 159 lines that write no `where`
clause and no dot-call, against the morning's 20.3 % by the same instrument on
this machine. The day made the compiler emit less and refuse more; it did not
make checking cheaper. **The number that most deserves attention** is the
black-box gate at **78.4 s**, 78.7 s warm, so there is no cache to warm: 2.5× C0,
the slowest thing any contributor waits for, and unlike every other row it sits
on the critical path of `CLAUDE.md`'s rule 4 twice per landing.

## 9. Could not determine

- **Why R3's `sortBy` penalty reads +6.1 % tonight where `128002b` recorded
  +18 % (783.9 → 928.2 ns/op).** Same machine, same harness, more runs, lower
  load; nothing in the eight intervening commits obviously touches dev-mode
  sorting. A bisect would settle it and was not run.
- **How much of §2's +24.5 % is static dispatch and how much is today's three
  new checker passes.** One instrument, one number; the morning's 20.3 % is the
  only lower bound and it is not a clean one.
- **Whether the 992-byte difference between one commit built in two directories
  matters.** Report 19 §16 records it at 40 and 8 bytes.
- **`backend.md` §13's esbuild row** — never measured, and no esbuild was run.
- **What `--library` costs against a real root rule** (§3 keeps every export),
  **whether the zero `ambiguous_method_receiver` count generalises** (§7), and
  **anything warm** — M4 has not started, so every build figure here is cold.
- **R1 and R2 through both compilers** — they no longer compile on B, so §5's
  pure-compiler column has four rows, not six.
