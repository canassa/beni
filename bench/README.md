# bench — measured numbers

`fast-compiler.md` §12: the budget is tracked as a visible trend, not a gate.
This file is the trend. **Newest entry first**, each dated, each naming the
machine it was taken on, because a number without a machine is not a number.

How to reproduce an entry:

```sh
direnv exec . zig build -Doptimize=ReleaseFast
direnv exec . zig build bench -- --generate=100000     # writes .zig-cache/bench-gen
time ./zig-out/bin/beni check --jobs=1 .zig-cache/bench-gen
```

Wall times are **best of 5** on an otherwise idle machine. Check the load
average first: an early draft of the M1d table was taken while another build
was saturating the four cores and read 784 ms where the real number was
51 ms — a 15× error that looked entirely plausible.

---

## 2026-09-29 — the parser, formatter and lowering read markup

**Machine 2**, as the entry below, every run pinned with `taskset -c 7`, interleaved against a
binary built from the commit before (the lexer's three review fixes, already in). The parser,
formatter and BIR lowering now read markup (`frontend.md` §9.4–§9.7).

**Markup-free parsing does not regress; markup-free lexing moved, and not because of the lexer.**
Medians (MB/s):

| corpus | lex before | lex after | parse before | parse after |
|---|---:|---:|---:|---:|
| `bench/corpus`, 7 runs (`--iterations=100`) | 231.6 | 222.9 | 308.4 | 308.2 |
| `--generate=100000`, 5 runs (`--iterations=40`) | 260.1 | 245.8 | 289.8 | 285.8 |

Counted with `perf_event_open` over the generated corpus, per iteration (40 minus 10, over 30):

| | lex instructions | lex cycles | lex branch misses | parse instructions | parse cycles |
|---|---:|---:|---:|---:|---:|
| before | 73 757 528 | 27.2 M | 206 580 | 65 868 113 | 24.6 M |
| after | 73 772 992 | 28.9 M | 270 945 | 66 801 091 | 25.1 M |
| before + the 22 new diagnostic codes only | 73 772 986 | 29.2 M | 310 388 | 66 315 012 | 24.5 M |

The lexer's source is byte-identical before and after, and it retires the same instructions; what
moved is branch misses, by a third. The last row is the commit before with nothing changed but 22
codes appended to `diagnostic.Code` and their titles, and it reproduces the whole lexing loss — worse
than the full change. So it is where code lands, not what it does: aligning `tokenize` to 64 bytes
or to 4 KiB did not recover it this time (it did in the entry below). Parsing retires 1.4 % more
instructions, half of that from the same 22 codes, for cycles within the runs' spread; testing the
token after a `pub` word before reading its text took the vocabulary declarations' lookahead from
+2.0 % to that.

**Markup itself**, `zig build bench -- --corpus=bench/markup --phases=lex,parse,lower
--iterations=500` (4 files, 553 lines, 19 853 bytes, 4 085 tokens, 2 007 nodes, 718 instructions),
three runs: lex **269–276 MB/s**; parse **420–430 MB/s, 12.3–12.6 M LOC/s**; lower **180–182 MB/s,
5.3 M LOC/s**, text trimming and entity decoding included.

---

## 2026-09-29 — the lexer's markup modes

**Machine 2** (AMD Ryzen 9 5950X, Linux 6.12.110, Zig 0.16.0, ReleaseFast),
load average about 1 on 32 threads, every run pinned to one core with
`taskset -c 7`. The lexer gained a mode stack for markup (`frontend.md`
§9.1–§9.3); this entry is its two measurements (§9.3).

**Markup-free code does not regress.** Eleven interleaved runs of the lex
line against a binary built from the commit before, medians (MB/s):

| corpus | before | after |
|---|---:|---:|
| `bench/corpus` (`--iterations=500`) | 243.2 | 240.7 |
| `--generate=100000`, 624 files (`--iterations=40`) | 263.0 | 270.3 |

Both differences sit inside the runs' spread (235–258 and 259–280). A first
cut, before this one, was 2–3 % slower on both; the two changes that removed
it are worth knowing: the markup states live in a function of their own so
`next`'s state machine is the one it was, and the 32 KiB stack array is a
local of `tokenize` that the tokenizer points at, not a field copied into
every file's tokenizer.

**Markup itself**, `zig build bench -- --corpus=bench/markup --phases=lex`
(4 files, 553 lines, 19 853 bytes, 4 085 tokens), five runs: **273–280 MB/s,
7.99–8.19 M LOC/s** — 32× `fast-compiler.md` §2's 250 k LOC/s, which is a
budget for the whole of checking and not for the lexer alone.

---

## 2026-09-18 — where the compiler stands, after the day M3 had

**The numbers are not here.** This entry exists so that the trend has a marker
at this date and points at the page that carries them:
[`plans/state-of-the-compiler.md`](../plans/state-of-the-compiler.md), taken on
`8be8e17` against the `c870e9a` baseline in one sitting on **machine 2** (AMD
Ryzen 9 5950X, 16 cores / 32 threads, 31 GiB, Linux 6.12.110, Zig 0.16.0, Node
v24.19.0, load 0.04–1.05 throughout).

The one-line summary, so this file is not silent about its own budget: **check
1.29 M LOC/s per core** against §2's 250 k; **a 100 k-line cold build in 109 ms**
(196 ms at `--jobs=1`) against §2's 800 ms; **emit 59–62 MB/s** against
`backend.md` §13's 5 MB/s; **an empty program ships 2 147 bytes** where it
shipped 65 214 before reachability elimination. The slowest thing in the repo
is now `zig build test-blackbox` at **78 s**.

### `bench/runtime/` — one note about the programs, not a number

Every program under `bench/runtime/c0/` and `c1/` splits its workload into
blocks (4 × 500, 40 × 500, 120 × 500) and each header explains that it does so
because `List.range 1 2000` was close to the JavaScript stack limit "until the
tail-call loop lands". **It landed, in `bbfc869` on 2026-09-18.** So the split
is now:

- **vestigial** for any compiler at or after `bbfc869` — `List.rangeHelp` and
  `List.mergeWithHelp` are labelled loops and a flat range would be fine;
- **mandatory** for the C0 baseline binary at `c870e9a`, which is still the A
  side of every C0-vs-C1 row and has no loop.

The programs are therefore **left exactly as they are**. Their `-- ops:` counts
and their checksums are cited all over
`plans/static-dispatch-spike-results.md`, and a program whose ops count moved
would void every row that quotes it. Only the sentences that claimed the loop
"has not landed" were corrected; no code, no count, no checksum changed.

---

## 2026-09-14 — M3a, the emitter's first number

**Machine:** Intel N100, 4 cores / 4 threads, 6 MiB L3, single memory
channel, 16 GB RAM, Linux 7.2, Zig 0.16.0, ReleaseFast, load average 1.3.

`zig build bench -- --generate=100000 --iterations=5`, the generated 624-file,
100 159-line corpus plus core:

| phase | ms | rate |
|---|---:|---|
| read | 2.1 | 818 MB/s |
| lex | 10.3 | 170 MB/s |
| parse | 7.0 | 251 MB/s |
| lower | 9.7 | 181 MB/s |
| resolve | 5.7 | — |
| check | 76.6 | 1.31 M LOC/s |
| **emit** | **34.3** | **85.5 MB/s of JavaScript** |
| total | 145.8 | — |

**`emit` is `backend.md` §13's line and its target is > 5 MB/s.** The
measured 85.5 MB/s is 17× it, on output that has had no elimination and no
renaming — 3.08 MB of JavaScript from 1.84 MB of beni, which is the ~1.7×
expansion development output costs and the number M3c's optimiser is
measured against.

Two things the figure does and does not say. It DOES say that the two-IR
design of §9.2 is not the bottleneck anyone feared: building a `JsIr` and
printing it costs less than half of what type checking the same corpus costs.
It does NOT say anything about release output, which is a different pass list
(§9) over the same graph.

`mb_per_s` on this row is measured over the JavaScript **produced**, not the
beni consumed, because that is how §2 states the budget.

---

## 2026-09-13 — M2d, **after**: the quadratics are gone

The entry below this one is the BEFORE, taken at `f0314b4` on the same
machine in the same session. This is the same corpus after the M2d review
fixes. Both binaries were `-Doptimize=ReleaseFast`; every pair was measured
**interleaved**, best of 3, because this machine drifts about 30 % over
minutes under load (the entry below explains why that matters).

**Machine:** Intel N100, 4 cores / 4 threads, 6 MiB L3, single memory
channel, 16 GB RAM, Linux 7.2, Zig 0.16.0, ReleaseFast, load average 1.8.

### The wide shape

`zig build bench -- --wide=<n>` then `beni check --jobs=1 .zig-cache/bench-wide`:

| `--wide=` | before | after | ratio |
|---:|---:|---:|---:|
| 2 000 | 268 ms | **31 ms** | 8.6× |
| 4 000 | 1 023 ms | **69 ms** | 14.8× |
| 8 000 | 4 265 ms | **176 ms** | 24.2× |
| 20 000 | 22 813 ms | **535 ms** | 42.6× |

Before: 4.0× per doubling, dead-straight n². After: 2.2–2.5×, and the
residual is the corpus itself — `WideShape` widens its records as `n` grows,
so the text grows faster than the declaration count does.

### The four loops on their own

Each is a synthetic module isolating one of them, `--jobs=1`, best of 3:

| shape | n | before | after |
|---|---:|---:|---:|
| one SCC of `n` **`pub`** declarations (writing the interface) | 2 000 | 16 ms | 7 ms |
| | 4 000 | 45 ms | 9 ms |
| | 8 000 | 152 ms | 14 ms |
| | 16 000 | 569 ms | 22 ms |
| | 32 000 | 2 412 ms | **43 ms** |
| `n` independent declarations (`Constrain.sccGroups`) | 8 000 | 54 ms | 27 ms |
| | 16 000 | 169 ms | 49 ms |
| | 32 000 | 532 ms | **96 ms** |
| `n` chained aliases (`Types.settleEquatable`) | 250 | 6 ms | 5 ms |
| | 1 000 | 15 ms | 6 ms |
| | 2 000 | 41 ms | **7 ms** |
| 200 functions × `n`-field records (field lookup, `unifyRecord`) | 100 | 50 ms | 23 ms |
| | 200 | 98 ms | 42 ms |
| | 400 | 203 ms | 76 ms |
| | 800 | 456 ms | **152 ms** |

What changed, in the order the time was in:

- **Writing the interface** was quadratic twice over. `fillInterface`
  resolved each `pub` value by scanning `bir.decls` and comparing symbols
  (O(values × declarations), and a name lookup checker.md §4.5 forbids); it
  now goes through `Interface.Provenance`, built in the walk that already
  knew the answer. And `Schemes.Writer.resetMemo` cleared two STORE-sized
  arrays once per exported value — invisible in a trace because it sits
  between the profiled events — which is now a `touched` list. The second
  one was the larger of the two and was in neither the review nor the first
  round of fixes; the wide corpus is what found it.
- **`sccGroups`** grouped members with a scan per component, which is
  quadratic on the *normal* shape of code (mostly independent declarations,
  so components ≈ n). Counting sort.
- **`settleEquatable`** re-scanned the whole type table each round. One pass
  collecting edges, then a worklist along them.
- **Record fields**: the literal/update lookups binary-search the sorted
  range instead of scanning it, and `unifyRecord` is the merge-join the
  `TypeStore` header always claimed it was — `gatherFields` sorts a
  flattened extension chain (and only then; a record that is not extended is
  already in order).

### The 624-file corpus is unchanged

`--generate=100000`, the shape every previous entry measures, `--jobs=1`:
**137 ms before, 137 ms after**. Per-phase, best of 3 interleaved:
`check` 74.8 → 76.0 ms, `constrain` 17.1 → 17.5, `solve` 39.3 → 40.4,
`graph` 3.7 → **0.8** (the condensation's Kahn loop is now linear). None of
the quadratics above is visible on 624 small files, which is the entire
reason the wide shape exists.

`instantiations` moved 73 934 → 55 231 and that is a FIX, not a
regression: an imported value was counted twice, once where its scheme was
produced and once by `makeCopy`. checker.md §9 has M4's incrementality tests
asserting this counter did not move, so it has to mean one thing.

### A new row in the trace

`types` (checker.md §5, numbering every declared type and settling
equatability) now has a profile event. It is 0.7 ms on the 100k corpus and
was 1.3 s of a 1.35 s compile on the alias-chain shape — a phase that can
dominate a build and does not appear in the trace defeats the instrument
(`fast-compiler.md` §12).

---

## 2026-09-13 — M2d, **before**: the wide corpus (one module, many `pub`)

**These numbers are a BEFORE.** They were taken at the M2d starting point,
`f0314b4`, with four superlinear loops still in the checker. The fixes land
in this same milestone. This entry is the baseline the next one is read
against; nothing in it describes what `beni check` does today.

**Machine:** Intel N100, 4 cores / 4 threads, 6 MiB L3, single memory
channel, 16 GB RAM, Linux 7.2, Zig 0.16.0, ReleaseFast. Best of 5, load
average 1.8–2.6 (shared machine). Every configuration below is run once
per round and the rounds are **interleaved**, not run block by block. Two
sequential blocks of one earlier batch, minutes apart, read 4 119 ms and
5 507 ms for the same corpus: that is the machine drifting, not the
compiler, and interleaving is what makes a 30 % drift cancel rather than
land on whichever row it happened to cover. Wall and child CPU time agree
to within 1 % on every row below, so the neighbours cost nothing
measurable.
**Corpus:** `bench/gen.zig --wide=<declarations>`, the second generated
shape. Everything is in ONE module, `Wide/Bulk.beni`; `Wide/Main.beni` is
nine lines that import it, so the interface it exports is one somebody
pays for. `beni check` is clean at every size.

### Why a second shape

`--generate=100000` writes 624 files of ~160 lines. That is the right
shape for throughput per byte and it is blind to anything quadratic in ONE
module's declaration count: however large the project grows, the biggest
module is still 160 lines, so every per-module term stays flat and the
trend line stays straight. Four superlinear loops lived under that line
from M2a to M2c and were found by reading the code rather than by
measuring it:

| pass | quadratic in |
|---|---|
| `Check.fillInterface` | exported values × the module's declarations |
| `Constrain.sccGroups` | SCC components × declarations |
| `Types.settleEquatable` | types × fixpoint rounds |
| the record-literal / record-update field lookups in `Constrain` | fields × fields, per literal |

`--wide=n` grows all four at once: `n` `pub` declarations, none of them
mutually recursive so the component count IS the declaration count; a
`type alias` chain `n/10` links long whose last link is a function type;
and `n/20`-field records built and updated by 40 functions. `WideShape` in
`bench/gen.zig` says which part of the budget is aimed at which cost.

### The trend

| `--wide=` | lines | `check --jobs=1` | `--jobs=4` | vs. previous size | LOC/s |
|---:|---:|---:|---:|---:|---:|
| 2 000 | 13 713 | 276 ms | 269 ms | — | 49 700 |
| 4 000 | 27 388 | 1 110 ms | 1 053 ms | **4.02×** | 24 700 |
| 8 000 | 54 738 | 4 300 ms | 4 177 ms | **3.87×** | 12 700 |
| 20 000 | 128 588 | 24 031 ms | — | **5.59×** (for 2.5× the size) | 5 400 |

Doubling the size costs four times the work, and 2.5× the size costs 5.6×.
That is the bend the 624-file corpus cannot draw: `--generate=100000` —
100 159 lines in 624 files — checks in **141 ms** in the same interleaved
batch, which is **710 000 LOC/s**. At `--wide=20000` the same checker on
the same machine manages 5 400, so the shape of a project is worth **130×**
here, and none of that shows in a corpus of small files.

**Worker count makes no difference.** `--jobs=4` is within 3 % of
`--jobs=1` at every size. M2c's scheduler parallelises across MODULES, and
a project whose work is one module has nothing for the other three workers
to take. The 1.94× of the M2c entry below is a statement about a
624-module project; this is the shape that says so.

### Where the time goes (`--self-profile`, `--wide=8000`, `--jobs=1`)

Best of 3, same machine state as the table above.

| | ms |
|---|---:|
| profiled span | 4 049.4 |
| `check` (the parent of the three below) | 4 010.6 |
| `solve` | 109.3 |
| `constrain` | 18.5 |
| `exhaustive` | 0.4 |
| every other event — `read`, `lex`, `parse`, `lower`, `resolve`, the serial steps | 24.4 |

`check` minus its own children is **3 882 ms, 95.9 % of the span**, and
none of it is inference: it is the per-module bookkeeping around inference,
the binding-group SCC and writing the module's interface. Inference itself
is 128 ms for 217 617 unifications — 3 % of the run.

### Which part of the shape buys which cost

`--wide=8000` with one family of declarations cut out, interleaved with
everything above. The generated module separates its declarations with
blank-line pairs, so each cut is a filter over those blocks.

| corpus | `check --jobs=1` | difference |
|---|---:|---:|
| all of it — 8 001 declarations, 800-link chain, 400-field records | 4 300 ms | — |
| the alias chain removed (801 declarations) | 4 130 ms | −170 ms |
| the wide records removed — 41 declarations of 8 001 | 1 568 ms | **−2 732 ms** |
| the 7 158 plain declarations removed | 183 ms | −4 117 ms |
| `pub` removed from all but three declarations | 221 ms | **−4 079 ms** |

Two rows carry the finding. 41 declarations out of 8 001 — half a percent
of the module — are **64 % of the time**; and the same 8 001 declarations
with `pub` deleted check **19× faster**, which is `fillInterface` and
nothing else. The differences sum to far more than the total, so these are
not independent costs: they are one cost with two inputs.

### A fifth superlinear term, which the review did not name

`fillInterface` is O(exported values × declarations) — and worse than
that. Every `Schemes.Writer.add` call, one per exported value, opens with
`resetMemo`, which `@memset`s two arrays **sized by the whole type store**.
So the real shape is

> O(exported values × type-store size)

and a module's type store is far larger than its declaration list: at
`--wide=8000` that is ~7 200 exported values against a store with a few
hundred thousand descriptors, which is billions of word writes, and it is
where the 3 882 ms goes.

Record width is what separates this from the declaration-count term, since
a field changes the type store and changes no declaration count. Holding
the 8 001 declarations fixed and varying only how many fields `Wide` has:

| fields in `Wide` | `check --jobs=1` | per field |
|---:|---:|---:|
| 0 — no records at all | 1 568 ms | — |
| 100 | 2 250 ms | 6.8 ms |
| 200 | 2 890 ms | 6.6 ms |
| 400 — what `--wide=8000` writes | 4 300 ms | 6.8 ms |

**6.8 ms per field, straight, at a constant declaration count.** Nothing
quadratic in declarations alone can draw that line, and `constrain` — where
the field-by-field lookups live — is 18.5 ms of the whole run, so it is not
that either.

The M2d branch replaces the whole-store clear with Elm's `touched` list,
and its own note measures the term at 135 ms for 8 000 mutually recursive
`pub` declarations. That is the same loop, 29× cheaper, because the module
it was measured on had no wide records and therefore a small store — which
is the argument for this corpus in one sentence: the size of the module
was never the whole input.

The other two terms are small at this size and neither will stay small.
Deleting the 800-link chain saves 170 ms of 4 300 — and that 170 ms is
everything the chain costs, `settleEquatable` plus 801 fewer declarations
to lex, parse, lower and scan — but the fixpoint grows as the square of
the chain, so it is the term that arrives at `--wide=20000`'s 2 000 links.
`sccGroups` and everything else that does not depend on `pub` fits inside
the 221 ms of the no-`pub` row. Both are worth fixing; neither is why this
corpus takes 24 seconds.

### Type-checking throughput (`zig build bench`, single-threaded)

```
bench: generated 2000 pub declarations (1758 simple, 200 chain links, 40 builders over 100 fields), 13713 lines, 197432 bytes under .zig-cache/bench-wide
{"phase":"check","modules":13,"lines":13713,"unifications":58659,"generalisations":25849,"instantiations":21056,"obligations":3,"diagnostics":0,"ms":259.25,"loc_per_s":52894,"cold_check_ms":266.1}
bench: generated 4000 pub declarations (3558 simple, 400 chain links, 40 builders over 200 fields), 27388 lines, 403218 bytes under .zig-cache/bench-wide
{"phase":"check","modules":13,"lines":27388,"unifications":111454,"generalisations":48612,"instantiations":40238,"obligations":3,"diagnostics":0,"ms":1013.04,"loc_per_s":27035,"cold_check_ms":1025.5}
bench: generated 8000 pub declarations (7158 simple, 800 chain links, 40 builders over 400 fields), 54738 lines, 816269 bytes under .zig-cache/bench-wide
{"phase":"check","modules":13,"lines":54738,"unifications":217619,"generalisations":94368,"instantiations":78947,"obligations":3,"diagnostics":0,"ms":4171.38,"loc_per_s":13122,"cold_check_ms":4195.5}
```

`loc_per_s` for `check` alone falls 52 894 → 27 035 → 13 122 as the module
grows, against the §2 target of 250 k per core and against the
**1 086 516** the 624-file corpus reports in the M2c entry below. Same
language, same checker, same machine: the per-module terms are the whole
difference, which is the argument for keeping this shape in the corpus
permanently.

### One thing the corpus caught on the way in

A 2 000-link alias chain named from a value ANNOTATION is a cost of its
own. An earlier draft of the generator wrote `apply : Chain0 -> Int ->
Int`, which expands every link, and at `--wide=20000` that one annotation
took the run from 24 s to **108 s** at `f0314b4` — a 4.5× penalty from
three words. On the M2d branch the same line is a `nesting_too_deep`
diagnostic instead, because a written type may not nest more than 512
deep, which would have left the corpus not checking clean. The generator
now names the chain's LAST link: the corpus is clean at every size, and
the chain is still there for the fixpoint to walk.

### Reproduce

```sh
direnv exec . zig build -Doptimize=ReleaseFast
direnv exec . zig build bench -- --wide=8000     # writes .zig-cache/bench-wide
time ./zig-out/bin/beni check --jobs=1 .zig-cache/bench-wide
```

---

## 2026-09-13 — M2c (DAG-parallel checking, exhaustiveness)

**Machine:** Intel N100, 4 cores / 4 threads, 6 MiB L3, single memory
channel, 16 GB RAM, Linux 7.2, Zig 0.16.0, ReleaseFast. Best of 15, load
average 1.3 (shared machine; an earlier pass at load 12 read 15-20 % high
across the board, which is the M1d warning above happening again).
**Corpus:** `bench/gen.zig --generate=100000` — 624 files, 100 159 lines,
1 840 323 bytes, 635 modules (core included), 3 787 edges. `beni check` on it
is clean, exhaustiveness included.

### Wall time by worker count

| command | `--jobs=1` | `--jobs=2` | `--jobs=4` | default (4) | speedup at 4 |
|---|---:|---:|---:|---:|---:|
| `check`, M2b (checker serial) | 137 ms | 117 ms | 110 ms | 110 ms | 1.25× |
| `check`, M2c (checker on the DAG) | 136 ms | 86 ms | **70 ms** | 71 ms | **1.94×** |

The M2b row is the same binary one commit earlier, measured the same way, and
it is why M2c did the work: at M2b the checker was **74 of the 137 ms** and
none of it parallelised, so four workers bought 1.25×. On the module DAG
(checker.md §4.4) it is 1.94×, and 40 ms comes off the wall clock of a
100k-line project.

`--jobs=1` is unchanged at 136 ms: exhaustiveness (checker.md §6.6) adds
3.4 ms and the rest is noise.

### Where the time goes (`--self-profile`, same corpus)

| | `check` j=1 | `check` j=4 |
|---|---:|---:|
| profiled span | 136.0 ms | 61.0 ms |
| total worker CPU | 106.9 ms | 151.0 ms |
| `read` | 4.8 | 7.0 |
| `lex` | 15.1 | 21.5 |
| `parse` | 11.4 | 16.3 |
| `lower` | 15.9 | 23.8 |
| `constrain` | 17.1 | 24.7 |
| `solve` | 39.2 | 53.2 |
| `exhaustive` | 3.4 | 4.5 |
| `enumerate` + `merge_interners` + `graph` + `resolve` + `render` (serial) | 10.1 | 12.1 |

`check` is the parent event of the three checker rows: 73.6 ms at j=1,
105.7 ms of CPU at j=4. Worker busy time at `--jobs=4` is
**37.8 / 37.1 / 38.4 / 37.6 ms** — within 3.5 %. The DAG scheduler keeps all
four fed for the whole run despite 3 787 edges and a core package every module
depends on; there is no straggler and no tail.

### Why 1.94×, and not 4×

Two limits, both measured rather than argued.

1. **The serial tail is 12.1 ms**: enumerate, the interner merge, the graph
   build and `resolve`, which is still one module at a time. That is 20 % of
   the `--jobs=4` span and it is the next thing worth parallelising.
2. **The machine gives about 2.65×, not 4×.** Four independent
   single-threaded `beni check` processes over the same corpus take **205 ms**
   wall against **136 ms** for one alone: an aggregate of 4 × 136 / 205 =
   **2.65×**. The same work costs 41 % more CPU when four workers do it
   (106.9 → 151.0 ms) and every phase inflates, `read` included, which is a
   syscall and a memcpy and contends on nothing of ours. This is an N100 —
   four Alder Lake-N E-cores sharing 6 MiB of L3 and one DDR channel — and a
   checker that builds a type store per module is memory-bound long before it
   is core-bound.

Against those two: the parallel part is 136.0 − 10.1 = 125.9 ms of work and
takes 61.0 − 12.1 = 48.9 ms at four workers, which is **2.57×, or 97 % of the
2.65× the machine will give**. Amdahl over the measured ceiling predicts a
span of 125.9 / 2.65 + 12.1 = 59.6 ms against the 61.0 ms measured, so 98 % of
the model. **The parallelism is kept**: 40 ms of wall time on the budget's own
corpus, for one ready queue and one reverse-edge table, scaling as close to
the machine's ceiling as the front end's does.

### Type checking throughput (`zig build bench`, single-threaded)

```
{"phase":"resolve","modules":635,"edges":3787,"interfaces":635,"ms":8.37,"cold_check_ms":44.3}
{"phase":"check","modules":635,"lines":100159,"unifications":234875,"generalisations":121908,"instantiations":73934,"obligations":3151,"diagnostics":0,"ms":92.18,"loc_per_s":1086516,"cold_check_ms":136.5}
{"phase":"total","files":624,"bytes":1840323,"tokens":302615,"nodes":223928,"insts":207449,"ms":130.4,"mb_per_s":13.5,"loc_per_s":768270}
```

**1.09 M LOC/s** for checking alone against the §2 target of 250 k LOC/s per
core, and 70 ms of wall clock for the whole cold pipeline against the 800 ms
budget. `zig build bench` runs the check single-threaded on purpose — the
target is stated per core — and this line was taken under a neighbour's load,
so read it as a floor.

### Pattern usefulness (checker.md §6.6)

`exhaustive` is **3.4 ms of 136**, 2.5 % of a cold check, over 635 modules.
Its scratch is one arena per WORKER reset per `case`, not one per module: at
one arena per module the same pass cost 7.1 ms, half of it mapping and
unmapping a 256 KiB chunk 635 times.

The work budget that bounds the exponential worst case is never approached by
real code. Turning it down until answers change: every `case` in `core/`, in
the `check` corpus and in the generated corpus is decided on a budget of
**50**, and a deliberately hostile 200-constructor × 200-branch `case` with
two-deep nests lands between **25 600 and 51 200** — and still finishes in
**6 ms**. The shipped budget is 200 000, so ~4 000× what real code needs and
4× what the hostile case needs.

| input | diagnostics | exit | time |
|---|---:|---:|---:|
| 200 constructors × 200 branches, two-deep nests | 1 | 1 | **6 ms** |
| 2 000-deep `Just (Just (…))` pattern (a legal tree) | 0 | 0 | 9 ms |
| 8 000-deep `Just (Just (…))` pattern (past the limit) | 2 | 1 | 10 ms |

### A segfault the M2c abuse scenarios found

`Just (Just (…))` is **two** tree levels per source level — `pat_ctor` over
`pat_paren` — and `Parse`'s depth guard charged one, so a 4096-charge pattern
built an 8192-deep tree. Every consumer walks that tree by recursion: 4 000
levels segfaulted `check`, `dump --stage=ast`, `dump --stage=bir` and `fmt`.
Two narrow fixes: `parsePatAtom` charges the guard as well, so the bound is on
the TREE and not on the source nesting; and every worker is now spawned with
an explicit 64 MiB stack (the size M2b measured for the checker), `--jobs=1`
included, so a crash can no longer depend on the worker count. The AST dump
runs on such a thread too — 4 090 nested parentheses in an *expression*
crashed it, which had nothing to do with patterns.

Cost of always spawning: `beni version` is 1-2 ms, unchanged; `fmt --check` is
70 ms at `--jobs=1` and 35 ms at the default, within noise of M1d's 57/26.

One number in the M1d table below is stale as a result and is left as it was
taken: 100 000 nested lambdas now produce **4095** diagnostics, not 4096,
because a lambda's parameter is a pattern atom and the depth guard charges one
for it. The bound moved by one level; nothing else about that input changed.

---

## 2026-09-13 — M1d (parallel driver, formatter on the workers)

**Machine:** Intel N100, 4 cores / 4 threads, 6 MiB L3, single memory
channel, 16 GB RAM, Linux 7.2, Zig 0.16.0, ReleaseFast.
**Corpus:** `bench/gen.zig --generate=100000` — 627 files, 100 073 lines,
1 825 939 bytes, 300 416 tokens, 221 471 AST nodes. `beni check` on it is
clean (zero diagnostics).

### Wall time by worker count

| command | `--jobs=1` | `--jobs=2` | `--jobs=4` | default (4) | speedup at 4 |
|---|---:|---:|---:|---:|---:|
| `check` | 51 ms | 31 ms | 25 ms | 25 ms | **2.1×** |
| `fmt --check` | 57 ms | 35 ms | 26 ms | 26 ms | **2.2×** |

`beni version` — the empty run — is 2 ms, so ~8 % of the `--jobs=4` wall
time is process start and exit. `--jobs` is capped at four times the CPU
count: `--jobs=20000` on one six-byte file used to spend 7.6 s building
twenty thousand arenas, interners and threads.

### Where the time goes (`--self-profile`, same corpus)

| | `check` j=1 | `check` j=4 | `fmt --check` j=1 | `fmt --check` j=4 |
|---|---:|---:|---:|---:|
| profiled span | 48.3 ms | 19.1 ms | 55.1 ms | 20.4 ms |
| total worker CPU | 47.8 ms | 65.5 ms | 54.6 ms | 71.4 ms |
| `read` | 5.0 | 7.0 | 4.9 | 6.5 |
| `lex` | 14.9 | 19.4 | 14.6 | 18.9 |
| `parse` | 11.2 | 16.1 | 11.4 | 16.8 |
| `lower` | 14.2 | 20.4 | — | — |
| `format` | — | — | 21.2 | 26.8 |
| `enumerate` + `merge_interners` + `render` (serial) | 2.6 | 2.6 | 2.5 | 2.4 |

Worker busy time at `--jobs=4` is 18.6 / 15.8 / 15.7 / 15.4 ms for `check`
and 20.0 / 17.3 / 17.2 / 17.0 ms for `fmt`: the work-stealing counter
balances the four queues to within 20 %, so nothing is waiting on a straggler.

### Why 2.1×, and not 4×

The serial part is not the limit. It is 2.6 ms — enumerate, the interner
merge and the render — against 48 ms of per-file work, so Amdahl alone would
predict 48/4 + 2.6 = 14.6 ms at four workers, not the 19.1 ms measured.

The gap is that **the same per-file work costs 37 % more CPU when four
workers do it** (47.8 → 65.5 ms). Every phase inflates, including `read`
(+40 %), which is a syscall and a memcpy and contends on nothing of ours.
That points at the machine, and the machine says so directly: **four
independent single-threaded `beni check` processes** over the same corpus
take **67-74 ms** wall against **51 ms** for one alone — an aggregate of
2.8-3.0×, not 4× (`fmt --check`: 78-81 ms against 57 ms, so 2.8-2.9×).
This is an N100: four Alder Lake-N E-cores sharing 6 MiB of L3 and one DDR
channel, and a front end that streams 1.8 MB of source into tens of
megabytes of token, tree and BIR arrays is memory-bound long before it is
core-bound.

Against that ~2.9× ceiling the driver gets 48.3/19.1 = **2.5×, or ~86 % of
what the machine will give**; for `fmt` it is 55.1/20.4 = 2.7×, or **~93 %**.
What remains is the 2.6 ms serial tail and ~5 ms of process start and
teardown outside the profiled span. Nothing in the driver is worth changing
for this workload on this machine; the numbers to re-take on a machine with
more memory bandwidth are the ones in the first table.

### `fmt` on the workers

Formatting was serial until M1d: `fmt --check` ran the parse phases in
parallel and then formatted every file on the main thread. It is now a
per-file worker phase (`Session.format_phases`) writing into a session-owned
buffer per file, and the command walks the files in index order afterwards
to compare, write and print — so the listing and the bytes are a function of
the sorted path list alone. `format` is 39 % of the per-file work at
`--jobs=1`, which is what the speedup reflects.

Measured effect at four workers: **34 ms → 26 ms**. At `--jobs=1` it is
50 ms before and 57 ms after — the same work plus one copy of each file's
canonical text into a session-owned buffer, which is what buys the
parallelism, and what the `formatted_bytes` counter now reports
(1 856 438 bytes for this corpus).

### Abuse inputs

`beni check --diagnostics=json`, best of 3, peak RSS from
`getrusage(RUSAGE_CHILDREN)` around the run. Every one of these exits
normally — none is a signal, a hang, or a partial write. These are
measurements of the inputs, not a list of tests: the few that reach a guard
or a fixed defect no corpus fixture does are `tests/blackbox/abuse_test.zig`'s.

| input | diagnostics | exit | time | peak RSS |
|---|---:|---:|---:|---:|
| 10 MB one-line list literal (valid) | 0 | 0 | **500 ms** | **228 MB** |
| 10 MB one-line string literal | 0 | 0 | 64 ms | 22 MB |
| 10 MB file that is one identifier | 1 | 1 | 39 ms | 31 MB |
| 100 000 nested parentheses | 1 | 1 | 9 ms | 13 MB |
| 100 000 nested lists | 1 | 1 | 9 ms | 13 MB |
| 100 000 nested lambdas `\x -> \x -> …` | 4096 | 1 | 19 ms | 19 MB |
| 8 000-link `1 + 1 + …` chain | 1 | 1 | 3 ms | 13 MB |
| 8 000-link `r.a.a.a…` chain | 1 | 1 | 3 ms | 13 MB |
| 8 000-link `r????…` chain | 1 | 1 | 3 ms | 13 MB |
| 200 000 blank lines | 0 | 0 | 2 ms | 13 MB |
| every byte value 0–255 | 162 | 1 | 2 ms | 14 MB |
| mixed CRLF / LF / bare CR | 3 | 1 | 1 ms | 13 MB |
| unterminated string / char / interpolation at EOF | 1 / 1 / 2 | 1 | 1 ms | 13 MB |
| unterminated `(` / `[` / `{` at EOF | 2 each | 1 | 1 ms | 13 MB |
| a file that is only `--\|` | 1 | 1 | 1 ms | 13 MB |
| a file that is only `\` | 1 | 1 | 1 ms | 13 MB |
| 1 MB `--` comment line | 0 | 0 | 3 ms | 13 MB |
| `(x as)` with no name | 1 | 1 | 1 ms | 13 MB |
| empty directory | 0 | 0 | 1 ms | 13 MB |
| 5 000 empty modules, `--jobs=1` | 0 | 0 | 32 ms | 19 MB |
| 5 000 empty modules, default jobs | 0 | 0 | 19 ms | 19 MB |
| directory with a non-`.beni` file and a hidden subdirectory | 0 | 0 | 1 ms | 13 MB |
| `.hidden.beni` named explicitly | 2 | 1 | 1 ms | 13 MB |
| symlink loop `dir/loop -> ..` | 0 | 0 | 1 ms | 13 MB |
| the same file twice on the command line | 1 | 1 | 1 ms | 13 MB |

The 13 MB floor is the empty process. Only one input is over 200 ms — the
10 MB list literal, which is 3.5 M tokens and 3.5 M nodes of *valid*
program, at 22 bytes of front-end memory per source byte. It is the
`--pathological=big-list` generator case.

**No diagnostics cap is needed.** The 100 000 nested lambdas were the
candidate — every parameter but the first shadows the one outside it — and
they produce 4096 diagnostics, not 100 000, because the parser's nesting
limit stops the parse first. Peak RSS is 19 MB, three orders of magnitude
under the 2 GB bar. A cap would only ever fire on input the nesting guard
has already bounded, and it would cost every honest run a counter.

### Per-phase throughput, single-threaded (`zig build bench`)

```
{"phase":"read","files":627,"bytes":1825939,"ms":2.1,"mb_per_s":815.9}
{"phase":"lex","files":627,"bytes":1825939,"tokens":300416,"ms":9.7,"mb_per_s":180.4}
{"phase":"parse","files":627,"nodes":221471,"ms":6.2,"mb_per_s":280.6}
{"phase":"lower","files":627,"insts":205562,"ms":8.8,"mb_per_s":198.4}
{"phase":"total","files":627,"ms":26.8,"mb_per_s":65.1}
```

These are warm best-of-5 per-phase numbers with everything preallocated, so
they are lower than the cold `check` above (48 ms) by design: `check` reads,
allocates and keeps every artifact once.
