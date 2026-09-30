# Which immutable array for `core/Array`: measured

**Status:** research, 2026-09-29. Not normative. It answers W35's second half
([`plans/browser-decisions.md`](../../../plans/browser-decisions.md): *"Its representation is chosen by
measurement … bundle size … is a concern"*), which is experiment **X2** in
[`plans/browser-platform.md`](../../../plans/browser-platform.md) §3 and the benchmark
[`backend.md`](../backend.md) §4 has parked since M3 (*"pending M3c's benchmark of a vector trie"*).
It extends [research 29](29-rendering-strategies-measured.md) §10, whose array column was a
copy-on-write JavaScript array and which said in so many words that nobody had measured which shape
beni should ship. Two further questions the owner added on 2026-09-29 are answered in §9 (could
`List` itself be array-backed, as Roc's is?) and §10 (typed arrays, as a reference for a future
numeric or `Bytes` type). A later one, whether one sequence type could replace both `List` and
`Array`, is §16; the same question on programs written array-first, with `push` at the end
instead of `::` and `reverse`, is §17. **Every candidate of this report on every scenario of
§3, §15, §16 and §17, in one batch, in Chrome and Node, is
[research 46](46-every-sequence-candidate-on-every-scenario.md)**: where the two disagree, 46 is the
later measurement and covers more.

**Method in one paragraph.** Every candidate is a real published build or a real compiler's output,
driven through one uniform adapter, one process (or one fresh headless-Chrome instance) per
candidate and engine, on four engines: Node 24.19 and Chrome 153 headless (both V8; Chrome has
pointer compression, Node does not), the SpiderMonkey 140.14 shell (standing in for Firefox) and Bun
1.4.2 (JavaScriptCore, standing in for Safari). Each cell is the **median of 7 samples** (3 when a
single call exceeds 400 ms), each sample at least 10 ms of repeated calls after at least 25 ms of
warm-up, with a full GC before each operation. The IQR and min–max of every cell are in the raw data;
§11 summarises the spread. Elements are small records (`{k, o}`), because that is what a UI's rows
are; integer-element pathologies are reported separately (§11). Machine: Ryzen 9 5950X, NixOS. The
scripts and raw JSONL are listed in §13. **No geometric mean appears anywhere below**, per CLAUDE.md
rule 8: tables quote per-operation medians, ratios are per operation and size, and orderings are
stated per engine.

---

## 0. Findings

1. **No single representation wins; the split is clean and the same on all four engines.** A plain
   JavaScript array used copy-on-write ("cow") is the fastest persistent representation for every
   *read* and every *bulk* operation at every size — `get`, iteration, `map`, `filter`, `foldl`,
   `slice`, `concat`, `eq`, `sort`, `toArray`, List interconversion — within 1.0–1.6× of a mutable
   native array. A 32-way trie with a tail wins every *single-element write* (`set`, `push`, `pop`,
   `swap`) from about 100 elements up, and above 10 000 elements it wins by two to four orders of
   magnitude. The crossover for writes is at 32–100 elements on every engine (§4.3).

2. **Copy-on-write has a cliff, and the cliff is where Elm programmers use `Array`.** At 100 000
   elements one `set` costs **27.5 µs in Chrome, 349 µs in SpiderMonkey and 512 µs in Node**
   (Node's 800 KB copies without pointer compression are GC-bound) against **96–797 ns** for the
   trie. A loop of `set`s or `push`es over a large array — a grid, a histogram, a DP table, building
   an array by `push` — is O(n²) under cow. A history of 1 000 versions of a 100 000-element array
   retains **400 KB per version** under cow and **526 bytes** under the trie (Chrome).

3. **Recommendation: a hybrid — a plain, never-mutated JavaScript array up to 1 024 elements, a
   32-way persistent vector with a tail above — written as beni's own small port, not a library.**
   It is within ~1.0–2.0× of cow on reads and bulk operations at UI sizes (≤ 1 000 rows, where it
   *is* cow), within ~1.1× of the trie on writes above 1 024 (where it *is* the trie), removes both
   cliffs, and ships as **≈1.5 KB brotli** for the whole first-order foreign surface (§6). §12
   gives the API and the `Array.beni` / `Array.js` split. Pure cow is the fallback if the owner
   weighs bytes (≈0.4 KB) over the write cliff; the representation is a `foreign type`, so the
   choice is reversible in one sibling file.

4. **No published library is the right thing to ship.** Immutable.js (**16.8 KB** brotli, does not
   tree-shake) and mori (**31.4 KB**) are 5–40× slower than cow on reads and bulk work and no faster
   than a 120-line trie on writes. funkia `list` (RRB) is the one with a genuine asymptotic edge —
   `slice`, `concat`, `insert`, `remove` in O(log n), 100–1 000× faster than anything else at
   100 000 — but is 4–12× slower on `get`/`foldl`/`filter`, 20–1 700× slower to convert to a JS
   array, and **4.4 KB**. Elm's own `Array`, compiled by `elm make --optimize`, costs **1.5 KB**
   and is 2–10× slower than the port on reads (every `get` allocates a `Maybe`, every fold goes
   through `A2`). Immer is a draft model, not a data structure: with its default auto-freeze a
   `set` on 1 000 elements costs **96 µs** in Chrome (10 000× a native write). `@collectable/list`
   **fails a differential test** (stale reads after `set`, then `Error: Unterminated tree growth`)
   and was excluded.

5. **Freezing costs more than it buys.** `Object.freeze` on every result makes V8's reads 3–4×
   slower and a 1 000-element `pop` **35 µs** in Chrome (4 900× native). Immutability is the
   compiler's guarantee, not the runtime's; `core/Array` must not freeze.

6. **Field identity (W27) holds for the recommended design by construction**, and must be written
   into the sibling: `set` of an identical value, a full `slice`, `append` with an empty side and a
   `filter` that keeps everything return **the same object** (§7). The ES2023 builtins (`with`,
   `toSpliced`) never do, and neither do mori, funkia or Elm's `Array`.

7. **An array-backed `List` is competitive only where the compiler can prove locality.** With slice
   *views* for `x :: rest` and local in-place building, array code beats the cons list on folds
   (3–10×), `foldr` (12–35×, because beni's `foldr` reverses a cons list), library `map` (2–7×) and
   accumulator loops (0.1–0.7× the cons time). But every `x :: xs` the compiler cannot prove local
   is an O(n) copy: 150–7 600× slower at 1 000–10 000 elements, and a non-tail-recursive
   `f x :: map f rest` holds O(n²) live memory and exhausts a 4 GB heap at 100 000. Roc avoids this
   with runtime reference counts (in-place when unique), which a garbage-collected JavaScript target
   does not have. **Keep `List` as cons cells; ship `Array` beside it** (§9).

8. **Typed arrays are a memory and interop tool, not a speed tool** (§10). They win bulk copies
   (`set`/`copyWithin`/`subarray`, 5–400×), allocation of large zeroed buffers (20–200×) and memory
   (1–8 bytes per element against 4–17 in Chrome), and lose every callback builtin (`map`, `filter`,
   `reduce` are 1.2–14× slower than on a packed plain array in V8 and JSC) and `push`-style growth.
   A `Bytes` type is worth it for interop and memory; a general numeric array type is not worth it
   on speed alone.

---

## 1. The candidates, and why each is in

| candidate | version / source | what it is | why it is in |
|---|---|---|---|
| **native mut** | — | a JS array mutated in place (`a[i] = v`, `push`, `pop`, `splice`, `sort`) | the ceiling; the ratio base of every table (owner, 2026-09-29) |
| **native CoW** | ES2023 builtins | `with`, `toSpliced`, `toSorted`, `concat`, spread, `Array.prototype.map/filter/reduce` | the copy-on-write array a JS programmer writes today |
| **cow (port)** | written here, 60 lines | plain JS array never mutated after construction; loops instead of callback builtins; identity-preserving no-ops; copies by a loop below 64 elements and `concat()` above | the smallest honest beni sibling |
| **cow+freeze** | the port + `Object.freeze` | as above, every result frozen | whether a runtime guard is affordable |
| **trie (port)** | written here, 200 lines | Clojure/Elm-shape 32-way persistent vector with a tail; variable-length nodes; `set` path-copies; `slice`/`insert`/`remove` rebuild | the smallest honest persistent vector |
| **hybrid N** | written here, 40 lines over the two | plain array up to N elements, the trie above; N ∈ {32, 256, 1 024, 4 096} | the owner's hybrid; four thresholds to find the knee |
| **Immutable.js** | `immutable` 5.1.9 | `List`: 32-way trie with tail, transient `withMutations` | the most-used JS persistent list |
| **mori** | `mori` 0.3.2 | ClojureScript's `PersistentVector`, compiled | the reference persistent vector |
| **funkia** | `list` 2.0.19 | RRB-tree with prefix/suffix buffers | the fast one; the only RRB here that passes the test |
| **Elm** | `elm/core` 1.0.5, `elm make --optimize` 0.19.2 | Elm's `Array` (32-way with tail) exactly as Elm compiles it, called through its uncurried `.f` | the design beni's `List` came from; `references/elm-core` |
| **Immer** | `immer` 11.1.18, `NODE_ENV=production` | `produce` over plain arrays, auto-freeze on (the default) | asked for; draft-based, see §8 |
| **Mutative** | `mutative` 1.3.0 (latest, source at `af06787`) | `create` over plain arrays: a Proxy draft, one flat copy on first write, no freeze by default | asked for (added later, Node only); §14 |
| ~~@collectable/list~~ | 5.1.0 | RRB | **excluded**: after a `set`, `iterate` still yields the old value, and a later `get` throws `Unterminated tree growth` (the differential test in `test.mjs`) |

Considered and not included: `rrb-vector` ports on npm are unmaintained forks of the same two
designs; Rust-`im`-style WASM vectors cannot hold JS objects without a handle table and are ruled
out by the bundle budget before any measurement. A `@thi.ng` or `seamless-immutable` style frozen
array is "cow+freeze".

Every adapter passes a differential test (`test.mjs`): 14 starting sizes from 0 to 33 000, 60 random
operations each, every result compared element-by-element with a plain-array reference, plus `get`,
`foldl`, `eq` and `≠` checks.

---

## 2. Which numbers to read first

Beni is browser-first (CLAUDE.md), so **Chrome is the primary engine**; SpiderMonkey and JSC decide
whether a conclusion is V8-specific; Node is reported because it is the harness platform and because
its lack of pointer compression changes one conclusion (§4.4). Sizes: **1 000** is a typical UI list
and R29's benchmark; **100 000** is where asymptotics show. The full tables for all six sizes on all
four engines are Appendix A.

---

## 3. Chrome, 1 000 and 100 000 elements

Median per call, and in brackets the multiple of the mutable native array for the same operation and
size. `native mut`'s `push` truncates every 4 096 calls, its `pop` is a pop+push pair, its
`insert`/`remove` alternate so the length stays n, and its `sort` includes an O(n) refill of the
buffer; its `map` is in place; its `filter`, `slice`, `concat`-free reads are the same loops as cow.
The harness costs 5–8 ns per call, which is most of every native write figure.

### 3.1 n = 1 000

| op | native mut | native CoW | cow (port) | trie (port) | hybrid 1024 | Immutable | mori | funkia | Elm |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| get | 1.9 ns | 1.9 ns (1.0×) | 1.9 ns (1.0×) | 6.3 ns (3.4×) | 3.8 ns (2.0×) | 10 ns (5.5×) | 9.8 ns (5.3×) | 8.9 ns (4.8×) | 15 ns (8.1×) |
| set | 9.3 ns | 132 ns (14×) | 136 ns (15×) | **50 ns (5.3×)** | 126 ns (14×) | 85 ns (9.2×) | 99 ns (11×) | 190 ns (20×) | 99 ns (11×) |
| push | 9.2 ns | 596 ns (65×) | 238 ns (26×) | **31 ns (3.4×)** | 252 ns (27×) | 86 ns (9.3×) | 32 ns (3.5×) | 37 ns (4.0×) | 36 ns (3.9×) |
| pop | 7.2 ns | 120 ns (17×) | 133 ns (18×) | **32 ns (4.5×)** | 130 ns (18×) | 65 ns (9.1×) | 33 ns (4.6×) | 37 ns (5.1×) | 55 ns (7.7×) |
| slice | 79 ns | 76 ns (1.0×) | 81 ns (1.0×) | 1.29 µs (16×) | 83 ns (1.0×) | 241 ns (3.0×) | **19 ns (0.2×)** | 120 ns (1.5×) | 2.01 µs (25×) |
| concat | 2.68 µs | 388 ns (0.1×) | 405 ns (0.2×) | 5.61 µs (2.1×) | 2.00 µs (0.7×) | 67.5 µs (25×) | 16.3 µs (6.1×) | 689 ns (0.3×) | 4.50 µs (1.7×) |
| insert | 56 ns | 161 ns (2.9×) | 1.65 µs (29×) | 2.53 µs (45×) | 1.75 µs (31×) | 33.7 µs (600×) | 20.2 µs (360×) | 723 ns (13×) | 4.28 µs (76×) |
| remove | 523 ns | 163 ns (0.3×) | 1.69 µs (3.2×) | 1.68 µs (3.2×) | 1.76 µs (3.4×) | 33.3 µs (64×) | 19.6 µs (38×) | 701 ns (1.3×) | 4.21 µs (8.0×) |
| swap | 7.0 ns | 249 ns (36×) | 123 ns (18×) | **72 ns (10×)** | 128 ns (18×) | 132 ns (19×) | 149 ns (21×) | 232 ns (33×) | 135 ns (19×) |
| map | 2.15 µs | 3.31 µs (1.5×) | 3.38 µs (1.6×) | 2.91 µs (1.4×) | 3.38 µs (1.6×) | 51.6 µs (24×) | 23.1 µs (11×) | 2.13 µs (1.0×) | 9.46 µs (4.4×) |
| filter | 2.38 µs | 2.86 µs (1.2×) | 2.56 µs (1.1×) | 8.57 µs (3.6×) | 2.50 µs (1.0×) | 53.2 µs (22×) | 21.9 µs (9.2×) | 10.1 µs (4.2×) | 15.8 µs (6.6×) |
| foldl | 1.21 µs | 1.18 µs (1.0×) | 1.25 µs (1.0×) | 1.44 µs (1.2×) | 1.35 µs (1.1×) | 21.6 µs (18×) | 9.94 µs (8.2×) | 7.97 µs (6.6×) | 10.7 µs (8.8×) |
| iterate | 4.86 µs | 4.98 µs (1.0×) | 4.94 µs (1.0×) | 7.48 µs (1.5×) | 5.65 µs (1.2×) | 15.1 µs (3.1×) | 10.5 µs (2.2×) | 12.6 µs (2.6×) | 10.7 µs (2.2×) |
| length | 0.8 ns | 0.8 ns | 0.8 ns | 0.8 ns | 2.0 ns (2.4×) | 0.8 ns | 3.9 ns (4.7×) | 0.8 ns | 0.8 ns |
| fromArray | 125 ns | 127 ns (1.0×) | 128 ns (1.0×) | 687 ns (5.5×) | 115 ns (0.9×) | 35.7 µs (286×) | 13.2 µs (106×) | 5.53 µs (44×) | 1.00 µs (8.0×) |
| toArray | 5.0 ns | 5.0 ns (1.0×) | 5.0 ns (1.0×) | 915 ns (181×) | 5.1 ns (1.0×) | 11.9 µs (2 353×) | 8.16 µs (1 618×) | 8.93 µs (1 771×) | 11.3 µs (2 232×) |
| fromCons | 3.02 µs | 3.29 µs (1.1×) | 3.22 µs (1.1×) | 3.95 µs (1.3×) | 3.44 µs (1.1×) | 49.7 µs (16×) | 16.8 µs (5.6×) | 9.12 µs (3.0×) | 3.87 µs (1.3×) |
| toCons | 1.42 µs | 1.90 µs (1.3×) | 1.39 µs (1.0×) | 1.63 µs (1.1×) | 1.45 µs (1.0×) | 21.3 µs (15×) | 18.1 µs (13×) | 1.73 µs (1.2×) | 9.16 µs (6.5×) |
| eq | 821 ns | 812 ns (1.0×) | 818 ns (1.0×) | 1.03 µs (1.3×) | 822 ns (1.0×) | 27.8 µs (34×) | 17.6 µs (21×) | 9.44 µs (11×) | 33.5 µs (41×) |
| sort | 148 µs | 143 µs (1.0×) | 140 µs (0.9×) | 143 µs (1.0×) | 149 µs (1.0×) | 256 µs (1.7×) | 247 µs (1.7×) | 187 µs (1.3×) | n/a |

### 3.2 n = 100 000

| op | native mut | native CoW | cow (port) | trie (port) | hybrid 1024 | Immutable | mori | funkia | Elm |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| get | 2.6 ns | 2.8 ns (1.1×) | 2.6 ns (1.0×) | 14 ns (5.3×) | 13 ns (5.2×) | 24 ns (9.2×) | 24 ns (9.2×) | 23 ns (9.0×) | 26 ns (10×) |
| set | 8.9 ns | 28.5 µs (3 186×) | 27.5 µs (3 076×) | **96 ns (11×)** | 107 ns (12×) | 164 ns (18×) | 279 ns (31×) | 314 ns (35×) | 181 ns (20×) |
| push | 7.3 ns | 86.8 µs (11 960×) | 27.9 µs (3 847×) | 78 ns (11×) | 83 ns (11×) | 174 ns (24×) | 144 ns (20×) | 94 ns (13×) | **22 ns (3.1×)** |
| pop | 6.8 ns | 66.0 µs (9 651×) | 24.9 µs (3 643×) | 34 ns (5.0×) | 33 ns (4.9×) | 84 ns (12×) | 34 ns (5.0×) | 40 ns (5.8×) | 218 ns (32×) |
| slice | 14.2 µs | 67.5 µs (4.7×) | 65.1 µs (4.6×) | 138 µs (9.7×) | 140 µs (9.8×) | 446 ns (0.03×) | **17 ns** | 249 ns (0.02×) | 179 µs (13×) |
| concat | 870 µs | 496 µs (0.6×) | 496 µs (0.6×) | 653 µs (0.8×) | 638 µs (0.7×) | 8.05 ms (9.3×) | 1.63 ms (1.9×) | **2.00 µs** | 396 µs (0.5×) |
| insert | 2.59 µs | 76.3 µs (29×) | 237 µs (91×) | 446 µs (172×) | 505 µs (195×) | 3.97 ms (1 533×) | 2.92 ms (1 130×) | **2.06 µs (0.8×)** | 404 µs (156×) |
| remove | 50.0 µs | 80.5 µs (1.6×) | 221 µs (4.4×) | 204 µs (4.1×) | 208 µs (4.2×) | 3.90 ms (78×) | 2.85 ms (57×) | **2.02 µs** | 396 µs (7.9×) |
| swap | 16 ns | 147 µs (9 292×) | 41.4 µs (2 616×) | **107 ns (6.8×)** | 103 ns (6.5×) | 199 ns (13×) | 275 ns (17×) | 420 ns (27×) | 342 ns (22×) |
| map | 257 µs | 1.04 ms (4.0×) | 464 µs (1.8×) | 277 µs (1.1×) | 291 µs (1.1×) | 7.45 ms (29×) | 2.36 ms (9.2×) | 217 µs (0.8×) | 1.03 ms (4.0×) |
| filter | 292 µs | 430 µs (1.5×) | 378 µs (1.3×) | 817 µs (2.8×) | 1.28 ms (4.4×) | 6.70 ms (23×) | 2.15 ms (7.4×) | 1.04 ms (3.6×) | 1.61 ms (5.5×) |
| foldl | 123 µs | 117 µs (0.9×) | 119 µs (1.0×) | 146 µs (1.2×) | 154 µs (1.3×) | 3.83 ms (31×) | 1.12 ms (9.1×) | 814 µs (6.6×) | 1.15 ms (9.3×) |
| iterate | 700 µs | 778 µs (1.1×) | 686 µs (1.0×) | 1.03 ms (1.5×) | 1.10 ms (1.6×) | 3.30 ms (4.7×) | 1.41 ms (2.0×) | 1.61 ms (2.3×) | 1.50 ms (2.1×) |
| fromArray | 191 µs | 75.4 µs (0.4×) | 47.7 µs (0.3×) | 71.3 µs (0.4×) | 170 µs (0.9×) | 5.75 ms (30×) | 1.43 ms (7.5×) | 580 µs (3.0×) | 108 µs (0.6×) |
| toArray | 5.1 ns | 5.3 ns | 5.0 ns | 183 µs | 202 µs | 3.15 ms | 850 µs | 838 µs | 1.03 ms |
| fromCons | 389 µs | 505 µs (1.3×) | 458 µs (1.2×) | 535 µs (1.4×) | 600 µs (1.5×) | 5.30 ms (14×) | 1.98 ms (5.1×) | 870 µs (2.2×) | 396 µs (1.0×) |
| toCons | 312 µs | 380 µs (1.2×) | 309 µs (1.0×) | 347 µs (1.1×) | 348 µs (1.1×) | 3.70 ms (12×) | 2.87 ms (9.2×) | 320 µs (1.0×) | 1.21 ms (3.9×) |
| eq | 90.7 µs | 120 µs (1.3×) | 90.7 µs (1.0×) | 111 µs (1.2×) | 118 µs (1.3×) | 5.65 ms (62×) | 2.92 ms (32×) | 989 µs (11×) | 3.80 ms (42×) |
| sort | 32.1 ms | 31.2 ms (1.0×) | 31.3 ms (1.0×) | 32.0 ms (1.0×) | 35.0 ms (1.1×) | 58.4 ms (1.8×) | 56.1 ms (1.7×) | 45.7 ms (1.4×) | n/a |

Immer and cow+freeze are omitted here for width; they are in Appendix A. At 100 000 Immer's `set`
is 9.65 ms and cow+freeze's `pop` 3.63 ms.

---

## 4. The same question on the other engines

### 4.1 Orderings

Fastest first, the persistent candidates only (native mut excluded; Immer, cow+freeze excluded as
dominated). "≈" joins medians within 10 %.

**n = 1 000**

| op | Chrome (V8) | SpiderMonkey | Bun (JSC) | Node (V8) |
|---|---|---|---|---|
| get | cow ≈ native CoW < hybrid < trie < funkia < mori ≈ Imm < Elm | cow ≈ CoW < hybrid < trie < Imm < mori < Elm < funkia | cow ≈ CoW < hybrid < trie < … | cow < CoW < hybrid < trie < funkia < Imm < Elm < mori |
| set | **trie** < Imm < Elm ≈ mori < hybrid ≈ CoW ≈ cow < funkia | **trie** < Imm < CoW ≈ cow < hybrid < mori ≈ Elm < funkia | **trie** < … < cow | **trie** < Imm < Elm ≈ mori < cow < funkia < hybrid < CoW |
| push | **trie** ≈ mori ≈ Elm ≈ funkia < Imm < cow ≈ hybrid < CoW | **trie** < mori < Elm < cow ≈ Imm ≈ funkia ≈ hybrid < CoW | **trie** ≈ Elm ≈ mori ≈ funkia < … < cow | **Elm** ≈ trie ≈ mori ≈ funkia < Imm < cow < hybrid < CoW |
| slice | **mori** < CoW ≈ cow ≈ hybrid < funkia < Imm < trie < Elm | **mori** < CoW ≈ cow ≈ hybrid < Imm < funkia < trie < Elm | mori < cow ≈ CoW ≈ hybrid < … < trie < Elm | mori < funkia ≈ hybrid ≈ cow < CoW < Imm < trie < Elm |
| concat | CoW ≈ cow < funkia < hybrid < Elm < trie < mori < Imm | CoW ≈ cow < hybrid < funkia < trie < Elm < mori < Imm | cow ≈ CoW < funkia < … | cow < funkia < CoW < hybrid < Elm < trie < mori < Imm |
| map | funkia < trie < CoW < cow ≈ hybrid < Elm < mori < Imm | cow ≈ hybrid < trie < CoW ≈ Elm < funkia < mori < Imm | funkia < cow < hybrid < … | funkia < trie < cow < CoW < hybrid < Elm < mori < Imm |
| filter | hybrid ≈ cow < CoW < trie < funkia < Elm < mori < Imm | cow < CoW ≈ hybrid < trie < Elm < mori < funkia < Imm | cow ≈ hybrid < CoW < … | cow < hybrid < CoW < trie < funkia < Elm < mori < Imm |
| foldl | CoW ≈ cow ≈ hybrid < trie < funkia < mori < Elm < Imm | trie ≈ cow ≈ hybrid < CoW < Elm < mori < Imm < funkia | cow < trie ≈ hybrid < … | cow < hybrid < trie < CoW < mori < funkia < Elm < Imm |
| toArray | cow ≈ CoW ≈ hybrid ≪ trie ≪ mori < funkia < Elm < Imm | same | same | same |

Appendix B has the machine-generated orderings for every operation at 100, 1 000 and 100 000 on all
four engines. **The ordering of cow against the trie is the same on every engine for every operation
at every size ≥ 1 000**: trie ahead on `set`/`push`/`pop`/`swap`, cow ahead on everything else. The
libraries move around; the two designs beni would ship do not.

### 4.2 SpiderMonkey and JSC at 100 000

| op | engine | cow (port) | trie (port) | hybrid 1024 | funkia | Elm | native mut |
|---|---|--:|--:|--:|--:|--:|--:|
| set | SpiderMonkey | 349 µs | 797 ns | 222 ns | 915 ns | 606 ns | 16 ns |
| set | Bun (JSC) | see App. A | | | | | |
| push | SpiderMonkey | 368 µs | 124 ns | 120 ns | 260 ns | 77 ns | 16 ns |
| get | SpiderMonkey | 3.2 ns | 29 ns | 32 ns | 68 ns | 78 ns | 3.4 ns |
| map | SpiderMonkey | 1.15 ms | 1.43 ms | 1.50 ms | 2.16 ms | 985 µs | 692 µs |
| filter | SpiderMonkey | 652 µs | 1.84 ms | 1.36 ms | 3.06 ms | 2.38 ms | 641 µs |
| toArray | SpiderMonkey | 8.0 ns | 456 µs | 479 µs | 1.39 ms | 1.55 ms | 8.1 ns |

(The Bun row is filled from Appendix A, which the reader should consult for JSC; the picture is the
same as Chrome's.)

### 4.3 Where the trie overtakes cow

`trie ÷ cow`, per operation, at n = 8 / 32 / 100 / 1 000 / 10 000 / 100 000. Below 1 the trie is
faster.

| op | Chrome (V8) | SpiderMonkey | Bun (JSC) | Node (V8) |
|---|---|---|---|---|
| get | 1.8 / 2.4 / 3.6 / 3.4 / 4.2 / 5.2 | 4.3 / 4.5 / 6.3 / 6.4 / 7.5 / 9.1 | 1.1 / 2.8 / 3.6 / 3.3 / 3.8 / 4.7 | 2.3 / 2.6 / 5.1 / 5.5 / 5.5 / 11 |
| set | 1.1 / 0.7 / 1.2 / **0.4** / 0.03 / 0.00 | 1.2 / 0.4 / 1.3 / **0.4** / 0.04 / 0.00 | 1.2 / 0.8 / 0.8 / **0.3** / 0.03 / 0.00 | 1.2 / 0.6 / 0.7 / **0.2** / 0.01 / 0.00 |
| push | 1.5 / 0.7 / 0.3 / **0.1** / 0.01 / 0.00 | 1.2 / 0.4 / 0.5 / **0.2** / 0.01 / 0.00 | 2.1 / 1.6 / 0.6 / **0.1** / 0.01 / 0.00 | 1.9 / 0.7 / 0.2 / **0.1** / 0.01 / 0.00 |
| pop | 1.1 / 1.2 / 0.8 / 0.2 / 0.02 / 0.00 | 1.3 / 1.2 / 0.6 / 0.2 / 0.01 / 0.00 | 1.2 / 1.4 / 0.3 / 0.03 / 0.00 / 0.00 | 0.8 / 1.0 / 0.5 / 0.1 / 0.00 / 0.00 |
| swap | 2.0 / 1.2 / 1.9 / 0.6 / 0.03 / 0.00 | 2.6 / 0.8 / 2.0 / 0.5 / 0.05 / 0.00 | 1.4 / 1.9 / 1.3 / 0.3 / 0.03 / 0.00 | 1.6 / 1.3 / 1.1 / 0.2 / 0.01 / 0.00 |
| slice | 3.3 / 3.3 / 7.8 / 16 / 13 / 2.1 | 4.3 / 5.0 / 8.2 / 15 / 9.7 / 65 | 7.5 / 7.6 / 8.4 / 6.6 / 7.7 / 11 | 3.8 / 2.9 / 6.3 / 13 / 6.1 / 4.8 |
| concat | 1.2 / 2.0 / 4.8 / 14 / 9.0 / 1.3 | 3.3 / 4.2 / 4.7 / 9.9 / 7.1 / 3.6 | 5.1 / 8.5 / 10 / 8.0 / 15 / 0.5 | 1.0 / 1.3 / 2.7 / 8.5 / 0.5 / 1.5 |
| map | 1.1 / 1.0 / 1.1 / 0.9 / 1.0 / 0.6 | 0.9 / 1.1 / 1.1 / 1.1 / 0.7 / 1.2 | 1.3 / 1.2 / 2.0 / 2.1 / 1.6 / 1.3 | 0.9 / 0.9 / 0.8 / 0.8 / 1.0 / 0.2 |
| filter | 1.2 / 1.2 / 1.6 / 3.4 / 3.3 / 2.2 | 2.5 / 2.2 / 1.5 / 2.3 / 2.6 / 2.8 | 1.7 / 2.2 / 3.2 / 3.4 / 2.0 / 1.5 | 1.0 / 3.3 / 1.6 / 2.9 / 2.5 / 2.2 |
| foldl | 1.1 / 1.1 / 1.1 / 1.2 / 1.2 / 1.2 | 1.5 / 1.0 / 0.4 / 1.0 / 1.0 / 1.2 | 0.9 / 1.6 / 1.2 / 1.5 / 1.5 / 1.8 | 0.8 / 0.8 / 1.0 / 1.2 / 1.3 / 1.6 |
| iterate | 1.0 / 1.5 / 1.5 / 1.5 / 1.5 / 1.5 | 2.0 / 1.2 / 0.9 / 1.4 / 1.4 / 1.5 | 0.7 / 3.0 / 1.3 / 1.3 / 2.3 / 3.4 | 0.7 / 1.1 / 1.3 / 1.3 / 2.0 / 1.8 |
| toArray | 12 / 13 / 39 / 183 / 1 853 / 36 291 | 11 / 14 / 32 / 700 / 6 208 / 56 895 | 14 / 28 / 46 / 356 / 2 787 / 73 389 | 11 / 11 / 46 / 280 / 3 285 / 116 207 |
| eq | 1.3 / 1.2 / 1.4 / 1.3 / 1.3 / 1.2 | 1.4 / 1.2 / 1.2 / 1.3 / 1.3 / 1.6 | 1.2 / 1.4 / 1.3 / 1.5 / 1.6 / 1.3 | 1.1 / 0.9 / 0.9 / 1.3 / 2.3 / 1.5 |

Single-element writes cross between 32 and 100 elements and are 3–10× in the trie's favour at
1 000. Everything else stays in cow's favour at every size; `toArray` — the thing an interop
boundary, a JSON encoder or a DOM API needs — is free for cow and O(n) for any tree.

### 4.4 Node is not Chrome at 100 000

Node 24 is built without pointer compression, so a 100 000-element array is 800 KB rather than
Chrome's 400 KB, and each copy goes to large-object space. The same `set` costs **512 µs in Node
and 27.5 µs in Chrome** (and 349 µs in SpiderMonkey); cow's `push` 513 µs against 27.9 µs. The
trie's figures agree across the two within 2×. Any cow figure measured under the Node harness
overstates the browser's cost at large sizes by up to 20×; the trie's does not.

---

## 5. What a UI does: R29's messages

The js-framework-benchmark-shaped model updates from R29 §10, rows `{id, label}`, `update` alone (no
DOM). `renderWalk` is what a keyed renderer does per render: walk the new sequence comparing each row
by `===` with the previous render's snapshot.

**Chrome, 1 000 rows** (× native in-place)

| message | native mut | native CoW | cow (port) | trie (port) | hybrid 1024 | Immutable | mori | funkia | Elm |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| swap 1↔998 | 6.9 ns | 539 ns (78×) | 267 ns (38×) | **68 ns (9.8×)** | 286 ns (41×) | 126 ns (18×) | 136 ns (20×) | 223 ns (32×) | 139 ns (20×) |
| update every 10th | 807 ns | 12.9 µs (16×) | 8.14 µs (10×) | 7.73 µs (9.6×) | 8.54 µs (11×) | 46.1 µs (57×) | 26.6 µs (33×) | 6.20 µs (7.7×) | 12.0 µs (15×) |
| append 1 000 | 3.52 µs | 595 ns (0.2×) | **566 ns (0.2×)** | 5.50 µs (1.6×) | 2.06 µs (0.6×) | 95.6 µs (27×) | 16.4 µs (4.7×) | 672 ns (0.2×) | 4.07 µs (1.2×) |
| remove one | 711 ns | 15.6 µs (22×) | **3.43 µs (4.8×)** | 11.2 µs (16×) | 9.81 µs (14×) | 85.5 µs (120×) | 24.7 µs (35×) | 13.3 µs (19×) | 23.0 µs (32×) |
| create 1 000 | 265 ns | 286 ns (1.1×) | 268 ns (1.0×) | 716 ns (2.7×) | 282 ns (1.1×) | 41.5 µs (156×) | 13.9 µs (53×) | 5.45 µs (21×) | 1.00 µs (3.8×) |
| renderWalk | 4.08 µs | 8.81 µs (2.2×) | **3.98 µs (1.0×)** | 8.91 µs (2.2×) | 4.17 µs (1.0×) | 21.5 µs (5.3×) | 13.1 µs (3.2×) | 13.8 µs (3.4×) | 13.8 µs (3.4×) |

**Chrome, 10 000 rows**

| message | native mut | native CoW | cow (port) | trie (port) | hybrid 1024 | Immutable | mori | funkia | Elm |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| swap 1↔998 | 7.3 ns | 5.77 µs (785×) | 2.92 µs (397×) | **120 ns (16×)** | 127 ns (17×) | 228 ns (31×) | 285 ns (39×) | 462 ns (63×) | 249 ns (34×) |
| update every 10th | 8.29 µs | 153 µs (18×) | 78.2 µs (9.4×) | 81.3 µs (9.8×) | 84.3 µs (10×) | 582 µs (70×) | 269 µs (32×) | 63.9 µs (7.7×) | 115 µs (14×) |
| append 1 000 | 2.01 µs | 3.36 µs (1.7×) | 3.50 µs (1.7×) | 5.57 µs (2.8×) | 6.26 µs (3.1×) | 67.6 µs (34×) | 16.5 µs (8.2×) | **1.24 µs (0.6×)** | 10.3 µs (5.1×) |
| remove one | 6.64 µs | 139 µs (21×) | **31.1 µs (4.7×)** | 110 µs (16×) | 179 µs (27×) | 980 µs (148×) | 248 µs (37×) | 144 µs (22×) | 220 µs (33×) |
| create 1 000 | 274 ns | 289 ns (1.1×) | 280 ns (1.0×) | 687 ns (2.5×) | 284 ns (1.0×) | 35.6 µs (130×) | 13.7 µs (50×) | 6.86 µs (25×) | 1.02 µs (3.7×) |
| renderWalk | 47.9 µs | 88.6 µs (1.8×) | **49.8 µs (1.0×)** | 89.2 µs (1.9×) | 98.3 µs (2.0×) | 283 µs (5.9×) | 133 µs (2.8×) | 168 µs (3.5×) | 136 µs (2.8×) |

In absolute terms, as R29 §10.3 already said of the cons list, none of this is a frame budget
problem: the worst persistent-candidate figure worth shipping here is 179 µs, 1 % of a 16.7 ms
frame. What the table does show is **where each design's money goes in a UI**: every message pays
one `renderWalk` (cow's strength), while only the message that changes the list pays a write. At
1 000 rows the hybrid *is* cow and inherits cow's walk; at 10 000 it is the trie and pays 2× on the
walk to make `swap` 23× cheaper. SpiderMonkey and JSC tell the same story (Appendix C).

---

## 6. Bundle size

Minified by esbuild 0.28 (tree-shaking on), then brotli at quality 11 — what a beni program would
ship for the **typical set**: `fromArray`, `toArray`, `get`, `set`, `push`, `slice`, `concat`,
`map`, `filter`, `foldl`, `length`, iteration, `fromCons`, `toCons`, `eq`. The **first-order set**
drops the callback functions (`map`, `filter`, `foldl`, iteration, `eq`) and adds `pop`, `swap`,
`insert`, `remove` — which is what a beni sibling would actually contain if higher-order functions
live in beni (§12.2). Adapters are included, and are a few dozen bytes each.

| candidate | typical: min | gzip | **brotli** | first-order: brotli | whole adapter: brotli |
|---|--:|--:|--:|--:|--:|
| cow (port) | 1 115 | 475 | **442** | **405** | 668 |
| cow+freeze | 1 416 | 602 | 568 | — | 760 |
| trie (port) | 3 283 | 1 213 | **1 134** | **1 073** | 1 466 |
| hybrid (port) | 4 835 | 1 660 | **1 562** | **1 473** | 2 012 |
| Elm `Array` (Δ of an `--optimize` program using it) | 5 016 | 1 670 | **1 501** | — | — |
| funkia `list` | 13 579 | 4 726 | **4 357** | — | 4 673 |
| Immer (+ cow reads) | 11 933 | 4 802 | **4 389** | — | 4 596 |
| Immutable.js | 66 158 | 18 762 | **16 786** | 16 714 | 16 928 |
| mori | 186 861 | 39 120 | **31 394** | — | 31 540 |

Immutable.js and mori do not tree-shake (class hierarchies and one Closure-compiled blob); funkia
does. For scale: beni's empty program is 2 149 bytes raw (CLAUDE.md), and R29 put Solid 2's whole
runtime at ≈5 KB brotli.

**How small can a beni port be?** The ports here are deliberately plain: the hybrid is the cow and
trie modules composed by a 40-line dispatcher that re-exports every operation. Written as one file
with the dispatch inlined into each export, sharing one `copy` helper, and dropping what beni writes
itself (§12.2), a first-order hybrid sibling is estimated at **1.1–1.3 KB brotli**; the measured
upper bound is 1.47 KB. Pure cow's first-order sibling is **≈0.4 KB**.

---

## 7. Field identity (W27)

The templates' per-hole `===` check (R29 P2/P3, W26, W27) depends on an untouched value being the
same object. For an array there are two levels. **Element identity** — the rows a template compares —
holds in every candidate: all of them store references, and an untouched row is the same object after
any operation (`elems-kept` below). **Container identity** is what lets a hole bound to `model.rows`
skip the whole list when an update was a no-op:

| candidate | `set` equal value | full `slice` | `append` empty | `filter` keeps all | `map` identity | `swap i i` |
|---|---|---|---|---|---|---|
| cow / trie / hybrid (ports) | **same** | **same** | **same** | **same** | new | **same** |
| native CoW (`with`, `toSpliced`) | new | new | new | new | new | new |
| Immutable.js | same | same | same | new | **same** | same |
| mori | new | new | new | new | new | new |
| funkia | new | same | same | new | new | new |
| Elm `Array` | new | same | new | new | new | new |
| Immer | same | same (cow's) | same (cow's) | same (cow's) | new | same |

(`results/identity.md`, at 100 and 5 000 elements; the answers do not depend on size.) The ports
return the same object whenever the result is equal element-by-reference, at the cost of one `===`
per no-op check. Immutable.js shows that `map` can too — it compares each result with the input and
returns the input when nothing changed — which costs one comparison per element and is worth
specifying for beni's `Array.map` so that a `map` that touched nothing does not wake a template
hole. **Recommendation: write these identities into `core/Array`'s documentation as guarantees**,
the way W27 was written for records.

---

## 8. Memory and GC pressure

**Retained bytes per element** (elements are shared records and are not counted — this is the
container), and **retained bytes per version** for a history of 1 000 versions each one `set` apart
(an undo stack, time travel, W25's model history).

| candidate | Chrome per element (n = 1 000 / 100 000) | Node per element | Chrome per version, n = 1 000 / 10 000 / 100 000 |
|---|--:|--:|--:|
| cow, cow+freeze, Immer | 4.0 / 4.0 | 8.1 / 8.0 | 4 025 / 39 989 / 399 629 |
| trie (port) | 5.0 / 4.9 | 10.0 / 9.8 | **339 / 393 / 526** |
| hybrid 1024 | 4.0 / 4.9 | 8.1 / 9.8 | 4 027 / 409 / 527 |
| Elm | 5.6 / 5.6 | 11.1 / 11.1 | 373 / 438 / 590 |
| mori | 5.6 / 5.6 | 11.3 / 11.1 | 418 / 557 / 721 |
| Immutable.js | 7.1 / 7.0 | 14.2 / 14.0 | 391 / 492 / 638 |
| funkia | 7.5 / 7.4 | 14.9 / 14.8 | 488 / 581 / 802 |
| *cons list* (beni's `List`) | 24 / 24 | 48 / 48 | — |

At 8 elements every tree pays its header: cow 7.7 B/element in Chrome, the trie 13.2, mori 34.8.
A cons cell costs 6× a cow slot, which is R29 §9.1's "24 bytes per row" from the other side.

**Bytes allocated per call** (Node, heap delta with a 512 MB young generation so no scavenge runs
inside a batch), the GC pressure each write creates:

| candidate | `set` n = 1 000 | `set` n = 100 000 | `push` 100 000 | `swap` 100 000 | `concat` 1 000 | `filter` 1 000 |
|---|--:|--:|--:|--:|--:|--:|
| cow | 8 187 | 800 074 | 800 154 | 800 074 | 16 384 | 11 565 |
| trie | **649** | **1 074** | **1 106** | **1 434** | 48 213 | 16 712 |
| hybrid 1024 | 8 188 | 1 074 | 5 054 | 1 434 | 37 428 | 11 565 |
| Elm | 697 | 1 202 | 146 | 2 130 | 23 902 | 32 558 |
| funkia | 1 234 | 2 074 | 658 | 2 690 | 3 702 | 10 477 |
| Immutable.js | 913 | 1 418 | 1 546 | 2 002 | 273 713 | 111 007 |
| Immer | 10 742 | 803 002 | 2 003 088 | 805 345 | 16 384 | 11 565 |

The 800 KB-per-`set` row is the whole reason cow's large-array writes cost what §4.4 shows.

---

## 9. Could `List` itself be array-backed? (the owner's second question)

Roc's `List` is a contiguous array. The question is whether beni's could be, given that Elm-style
code is written for cons: `x :: rest` destructuring in recursive walks, `foldr`/`foldl`, `map` by
recursion, and lists built by prepending in a loop. The **cons column is beni's real compiler output**
(`beni build --release`, `core/List` included — `beni-src/ListStyle.beni`); the array columns are
hand-emitted in exactly the same loop shapes (labelled `while (true)` loops for self tail calls,
`Basics.add` calls left as calls):

* **arr-copy** — `rest` is `list.slice(1)`; `x :: xs` copies.
* **arr-view** — `rest` is a view `{a, o}` (the array and an offset), no copy; `x :: xs` copies.
* **arr-view-scalar** — the view replaced by an offset local, which is what a compiler would emit
  when `rest` only flows back into the loop's own parameter.
* **+local / arr-local** — "local in-place building": the compiler proves the accumulator is local to
  the loop, so `x :: acc` is a `push` and the result is reversed once at the end (appending needs no
  reverse). Freezing at the end was not measured: immutability is static.

**Chrome** (× the cons list; SpiderMonkey, JSC and Node in Appendix D)

| code | representation | 1 000 | 10 000 | 100 000 |
|---|---|--:|--:|--:|
| walk `x :: rest` (sum) | **cons** | 1.48 µs | 14.6 µs | 159 µs |
| | arr-copy | 74.8 µs (50×) | 13.1 ms (900×) | 6.07 s (38 123×) |
| | arr-view | 1.97 µs (1.3×) | 19.9 µs (1.4×) | 170 µs (1.1×) |
| | arr-view-scalar | 456 ns (0.3×) | 4.77 µs (0.3×) | 75.2 µs (0.5×) |
| `List.foldl` | **cons** | 1.51 µs | 15.3 µs | 727 µs |
| | array | 421 ns (0.3×) | 3.47 µs (0.2×) | 75.0 µs (0.1×) |
| `List.foldr` | **cons** (reverse, then foldl) | 12.6 µs | 127 µs | 1.74 ms |
| | array (backwards loop) | 450 ns (0.04×) | 4.69 µs (0.04×) | 87.2 µs (0.05×) |
| `map` by recursion, `f x :: map f rest` | **cons** | 5.18 µs | 74.8 µs | stack overflow |
| | arr-copy | 1.68 ms (324×) | stack overflow | not run (O(n²) live memory) |
| | arr-view | 1.47 ms (284×) | stack overflow | not run (O(n²) live memory) |
| `map` by accumulator + `reverse` | **cons** | 9.03 µs | 93.3 µs | 1.07 ms |
| | arr-copy | 1.60 ms (177×) | 142 ms (1 518×) | 21.6 s (20 065×) |
| | arr-view | 1.41 ms (157×) | 122 ms (1 309×) | 13.4 s (12 484×) |
| | arr-copy + local | 138 µs (15×) | 13.0 ms (139×) | 5.95 s (5 535×) |
| | **arr-view + local** | **5.37 µs (0.6×)** | **44.8 µs (0.5×)** | **479 µs (0.4×)** |
| `List.map` (library) | **cons** | 14.2 µs | 61.3 µs | 867 µs |
| | array | 2.71 µs (0.2×) | 23.2 µs (0.4×) | 348 µs (0.4×) |
| build by prepending, `i :: acc` | **cons** | 1.57 µs | 16.2 µs | 309 µs |
| | arr, a copy per step | 1.50 ms (952×) | 124 ms (7 651×) | 12.2 s (39 496×) |
| | **arr, local building** | 3.43 µs (2.2×) | 26.8 µs (1.7×) | 289 µs (0.9×) |
| build by appending, `acc ++ [i]` | **cons** | 2.02 ms | 218 ms | 42.1 s |
| | arr, a copy per step | 177 µs (0.09×) | 14.4 ms (0.07×) | 8.07 s (0.2×) |
| | **arr, local building** | 2.72 µs (0.00×) | 20.9 µs (0.00×) | 460 µs (0.00×) |

What it says:

1. **Slice copies are never viable.** `rest = slice(1)` makes every walk O(n²): 50–38 000× the cons
   list. Any array-backed `List` needs views.
2. **Views are competitive for walks, and scalar-replaced views beat cons.** An allocated view costs
   1.1–2.3× cons (one small object per step, like a cons cell but read from a contiguous array); an
   offset local costs 0.3–0.6×. SpiderMonkey and JSC agree within the same ranges.
3. **Folds and library functions are much faster on arrays**: `foldl` 0.1–0.3× and `foldr`
   0.03–0.08× the cons time on every engine, because beni's `foldr` is `reverse` then `foldl`
   (`core/List.beni`) and an array can run backwards.
4. **Construction is where the design lives or dies.** With local in-place building, prepending is
   0.9–2.2× cons and appending is effectively free (cons `++` is itself O(n) per step: 42 s at
   100 000). **Without it, one `x :: xs` is an O(n) copy** — 950–39 000× cons.
5. **`f x :: map f rest` — non-tail recursion, the most Elm-shaped code there is — has no local
   accumulator for the analysis to find.** On arrays it is O(n²) in time and, because every frame
   holds its own `rest`, O(n²) in *live memory*: at 100 000 it exhausted Node's 4 GB heap
   ("Ineffective mark-compacts near heap limit"), so the 100 000 cell was not run on any engine.
   (The cons version overflows the stack at 100 000 on every engine too, for the ordinary reason.)
   A compiler could rewrite this shape (tail recursion modulo cons becomes a `push` loop), but that
   is another analysis, and it still does nothing for a `::` onto a tail that is shared.

**Verdict.** An array-backed `List` with slice views plus local in-place building **is competitive —
faster, in fact — on the code the analysis can see**: walks, folds, library calls, and accumulator
loops that build locally. It is **not competitive as a general representation**, because the
guarantee a cons list gives for free — `x :: xs` is O(1) whatever `xs` is and whoever else holds it —
becomes a property of an optimisation. When the optimisation misses (non-tail construction, a tail
shared with another value, a list built across messages, a persistent stack), the cost is 2–4
orders of magnitude, silently. Roc gets away with a contiguous `List` because reference counting
tells it *at run time* that a list is unique and can be mutated in place; a JavaScript target has no
reference counts, so beni would have to prove uniqueness statically everywhere a cons appears.
**Keep `List` as cons cells, and ship `Array` beside it.** The measurements do suggest two cheap
things for `List` itself: `foldr` over a cons list could materialise to a JS array and run
backwards (it already allocates n cells for `reverse`), and the view-plus-offset shape is how
`core/Array`'s own beni-written loops should be emitted.

---

## 10. Typed arrays against plain arrays (reference only)

The owner asked for this as a reference for a future numeric or `Bytes` type, not as a candidate for
`core/Array`. One process per element kind, so every loop is monomorphic. `plainSmi`/`plainDouble`
are plain arrays that stay in V8's packed small-integer / packed double kinds; `genSmi`/`genDouble`
are the same arrays after one non-number was stored and removed (V8's generic `PACKED_ELEMENTS`,
where doubles are boxed). "From a length" for plain arrays is a `push` loop (so the array stays
packed), which is the fair equivalent of `new Int32Array(n)`'s zero fill.

**Chrome, n = 1 000 000** (per call)

| op | plainSmi | genSmi | Int32 | Uint8 | plainDouble | genDouble | Float64 | Float32 |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| allocate from a length | 7.65 ms | 7.95 ms | **34.9 µs** | **31.6 µs** | 6.85 ms | 7.20 ms | **37.2 µs** | 40.1 µs |
| from values (a plain array) | 2.00 ms | 1.87 ms | 2.28 ms | 858 µs | 4.27 ms | 2.02 ms | 5.45 ms | 2.58 ms |
| `get` loop (sum) | 875 µs | 1.14 ms | 1.17 ms | 620 µs | 808 µs | 869 µs | 842 µs | 875 µs |
| `reduce` | 9.00 ms | 8.75 ms | 10.3 ms | 8.85 ms | **777 µs** | 858 µs | 10.6 ms | 10.5 ms |
| `set` in place, loop | **303 µs** | 297 µs | 567 µs | 528 µs | 468 µs | 17.6 ms | 613 µs | 620 µs |
| copy-on-write `set` (`slice` + write) | 2.02 ms | 1.77 ms | 1.98 ms | 552 µs | 4.20 ms | 1.87 ms | 4.07 ms | 2.05 ms |
| `map` builtin | 11.0 ms | 11.0 ms | 11.2 ms | 10.5 ms | 12.6 ms | 12.4 ms | 14.8 ms | 11.9 ms |
| `map` by a loop | 7.05 ms | 6.85 ms | 2.83 ms | **1.40 ms** | 6.80 ms | 6.90 ms | 4.47 ms | 2.75 ms |
| `filter` | **12.1 ms** | 13.6 ms | 43.8 ms | 41.3 ms | 18.4 ms | 12.5 ms | 56.9 ms | 54.2 ms |
| `subarray` view (half) | — | — | **33 ns** | 67 ns | — | — | 33 ns | 33 ns |
| `slice` copy (half) | 858 µs | 900 µs | 1.00 ms | 236 µs | 1.64 ms | 900 µs | 1.82 ms | 1.01 ms |
| bulk `set(src)` | — | — | **89.6 µs** | 21.7 µs | — | — | 187 µs | 89.1 µs |
| loop copy | 357 µs | 618 µs | 644 µs | 638 µs | 386 µs | 1.03 ms | 624 µs | 606 µs |
| `copyWithin` (half) | 213 µs | 217 µs | 44.6 µs | 10.9 µs | 88.0 µs | 505 µs | 85.6 µs | 42.9 µs |
| `push` growth (typed: doubling) | 5.75 ms | 6.35 ms | 5.90 ms | 3.05 ms | 9.10 ms | 12.1 ms | 9.40 ms | 6.05 ms |

**Chrome, n = 8** (per call; the many-small row is per array, 1 000 per call, each filled and summed)

| op | plainSmi | Int32 | Uint8 | plainDouble | genDouble | Float64 |
|---|--:|--:|--:|--:|--:|--:|
| allocate from a length | 27 ns | 30 ns | 30 ns | 28 ns | 26 ns | 30 ns |
| from values | **19 ns** | 77 ns | 77 ns | 18 ns | 18 ns | 84 ns |
| many short-lived small arrays | **18 ns** | 24 ns | 23 ns | 65 ns | 32 ns | 26 ns |
| `reduce` | **7.7 ns** | 77 ns | 76 ns | 8.2 ns | 9.6 ns | 95 ns |
| copy-on-write `set` | **18 ns** | 45 ns (35 via ctor) | 44 ns | 21 ns | 18 ns | 52 ns |
| `filter` | **27 ns** | 269 ns | 264 ns | 29 ns | 30 ns | 203 ns |
| `push` growth | **25 ns** | 368 ns | 350 ns | 27 ns | 26 ns | 338 ns |

**Memory, bytes per element** (Chrome / Node):

| arrays | plainSmi | genSmi | Int32 | Uint8 | plainDouble | genDouble | Float64 | Float32 | BigInt64 |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| one of 1 000 000 | 5.2 / 10.4 | 5.2 / 10.4 | 4.0 / 4.0 | 1.0 / 1.0 | 10.4 / 10.4 | **17.2 / 26.4** | 8.0 / 8.0 | 4.0 / 4.0 | 8.0 / 8.0 |
| 10 000 of 100 | 5.9 / 11.8 | 5.9 / 11.8 | 5.2 / 6.1 | 2.2 / 3.1 | 11.5 / 11.8 | 17.8 / 27.6 | 9.2 / 10.1 | 5.2 / 6.1 | 9.2 / 10.1 |
| 10 000 of 8 | 12.0 / 24.1 | 12.0 / 24.1 | 19.5 / 32.0 | 16.5 / 29.0 | 20.5 / 24.0 | 22.5 / 38.0 | 23.5 / 36.0 | 19.5 / 32.0 | 23.5 / 36.0 |

(The plain figures include `push`'s 1.3× growth slack.) **GC pressure of many small arrays** (Node,
bytes allocated per array, filled): 8 elements — plain 184, Int32 248, Uint8 225, Float64 280;
32 elements — plain 544, Int32 200 + 128 off-heap, Float64 200 + 256 off-heap; 100 elements — plain
2 361 (the growth copies), Int32 200 + 400, Float64 200 + 800. A typed array's JS object costs
≈200 bytes whatever its length; above 64 bytes its storage moves off-heap.

Across engines (Appendix E): JSC agrees with V8 on every row that matters, with smaller gaps
(`reduce` 20× in typed arrays' disfavour at 1 000 000, `map` loop 2–5× in their favour);
SpiderMonkey's shell figures for this section were measured while other engines were running and
are the noisiest in the report — they agree on direction for allocation, bulk copies and
`subarray`, and are not quoted for anything finer.

**Verdict.**

* **Typed arrays are faster** for: allocating large zeroed buffers (20–200×), bulk copies
  (`set`, `copyWithin`: 5–400×), O(1) `subarray` views, and — at large sizes — loops that write a
  fresh typed array (`map` by a loop 2.5–5× faster than a plain `push` loop), plus Uint8 anything
  (it moves an eighth of the bytes).
* **Plain arrays are faster** for: every callback builtin (`map`, `filter`, `reduce`, `from`:
  typed arrays' builtins are 3–14× slower in V8 and JSC, because V8 inlines the plain-array builtins
  into TurboFan and not the typed-array ones), small arrays (≤ 100 elements: creation from values
  4×, `filter` 10×, growth 14×), and anything that grows.
* **The generic element kind is the real trap for plain numeric arrays**: one stored non-number turns
  every double into a heap box (17–26 bytes per element instead of 8–10) and in-place writes 37×
  slower (`genDouble`'s 17.6 ms). A beni array of `Float` whose sibling never stores a non-number
  cannot fall into it — which is a point for beni's monomorphic types, not for typed arrays.
* **For beni**: a `Bytes` type (Uint8Array) is worth having for interop — `fetch`, `crypto`,
  `TextEncoder`, canvas, WebSocket all speak it — and for memory. A general `FloatArray`/`IntArray`
  is worth it only for memory (a 1 000 000-element `Float32Array` is 4 MB against 10 MB) and for
  bulk-copy-heavy code; on the speed of ordinary element-wise code it is a wash or a loss. Neither
  belongs in `core/Array`.

---

## 11. Caveats, and what could not be measured

* **Spread.** Median IQR / median across all cells: Node 2.7 %, Chrome 2.7 %, SpiderMonkey 2.4 %,
  Bun 3.5 %. Cells whose min–max range exceeds 25 % of the median: 21 %, 15 %, 28 % and 22 %
  respectively — mostly sub-10 ns cells (timer and loop overhead) and 100 000-element write cells
  (GC). No ordering claimed above rests on a difference smaller than 1.5×.
* **Concurrency.** The four engines ran in parallel, one process each, on a 16-core machine, and the
  typed-array SpiderMonkey runs overlapped the others. Frequency scaling and memory bandwidth are
  shared; the differences quoted are large relative to that.
* **Chrome's timer** is coarsened to 100 µs without cross-origin isolation; every sample is ≥ 10 ms,
  so the error is ≤ 1 %, but sub-nanosecond differences in Chrome columns are not meaningful.
* **The harness costs 5–8 ns per call.** Native in-place writes (7–30 ns) are mostly harness; their
  ratios are therefore *understated* multiples of a true native write.
* **Integer elements behave differently.** A first run with SMI elements showed V8's
  `slice()`+store on a small-integer array at 75 ns for 8 elements against 24 ns with records, and
  SpiderMonkey's `slice` of a 1 000-element int array 5× slower than `concat()`. The records used
  everywhere above are the UI case; an `Array Int` of game-board cells may see different constants
  (not different orderings) for cow.
* **Node figures for cow at 100 000 are GC-bound** (§4.4) and not representative of a browser.
* **The ports are minimal.** The trie's `slice`, `insert`, `remove` and `concat` rebuild in O(n);
  a production port would give `slice 0 k` (take) O(log n) sharing, which Elm and Clojure do. RRB
  (funkia) is the only design with O(log n) `concat`/`insert`/`slice` and was not ported.
* **Libraries run through arrow-function adapters** (e.g. Immutable's `reduce` callback is wrapped to
  swap arguments); this adds a call per element to their folds. Elm is called through `.f`, which
  skips the outer `A2` but not the internal ones.
* **Not measured**: a real Firefox or Safari (the SpiderMonkey shell and Bun stand in; Playwright's
  Firefox would not start on NixOS for lack of `libgtk-3`, as in the derived-comparison study),
  mobile CPUs, beni-compiled `Array` code (the compiler has no `Array` yet — the adapters are what
  its sibling would be), SpiderMonkey/JSC heap sizes (their shells expose no comparable
  per-object heap figure), and real-page GC pauses.

---

## 12. Recommendation

### 12.1 The representation

**`core/Array` is a hybrid: a plain JavaScript array, never mutated after construction, for arrays of
up to 1 024 elements; a 32-way persistent vector with a 32-element tail (the Clojure/Elm shape) for
arrays above.** The representation of a given length is canonical (≤ 1 024 is always the plain
array), so `eq` and the renderer can switch on it cheaply.

Why 1 024: the write crossover is at 32–100 elements, but below 1 024 the plain array's writes are
still ≤ 250 ns on every engine (Chrome 136 ns `set`, 238 ns `push` at 1 000), while its reads, walks,
`filter`, `slice`, `concat` and zero-cost `toArray` are what a UI list does on *every* render.
Hybrid 256 makes a 1 000-row list a trie and costs it 2× on `renderWalk`, 3.4× on `filter`, 180× on
`toArray` to save ~100 ns per write; hybrid 4 096 lets a single write reach ~2 µs. The plateau is
roughly 512–2 048; 1 024 is in the middle and is a power of 32.

What it costs, against the alternatives:

| | pure cow | **hybrid 1 024** | trie only |
|---|---|---|---|
| reads, walks, bulk ops ≤ 1 024 | best | **= cow** | 1.2–3.6× slower, `toArray` O(n) |
| single writes ≤ 1 024 | 15–26× native | **= cow** | 3–5× native |
| reads > 1 024 | best | 1.2–5× slower (`get` 13 ns vs 2.6 at 100 000) | same as hybrid |
| single writes > 1 024 | **O(n): 2–30 µs at 10 000, 28–512 µs at 100 000** | **≈ trie: 70–220 ns** | 70–800 ns |
| history of versions, 100 000 | 400 KB each | **≈ 0.5 KB each** | ≈ 0.5 KB each |
| interop (JS array out) | free | free ≤ 1 024, O(n) above | O(n) always |
| brotli, first-order sibling | **≈ 0.4 KB** | ≈ 1.1–1.5 KB | ≈ 1.1 KB |

**If the owner weighs the ~1 KB above the write cliff, pure cow is the fallback**, and "local
in-place building" (§9) would then be needed in the compiler to keep `push`-in-a-loop linear. The
choice is reversible: `Array` is a `foreign type` and only the sibling knows its shape.

### 12.2 What goes in `Array.beni` and what in `Array.js`

`core/List.js` records the rule this must follow: higher-order functions left the JavaScript sibling
for beni, because *"a JavaScript loop cannot park when its beni callback suspends"*
(backend.md §8; research 17 §3.4). So the sibling is **first-order**, and `map`, `filter`, `foldl`,
`foldr`, `indexedMap`, `initialize` are beni over it. Measured cost of that choice (the `foldlGet`
and `mapViaList` rows, Appendix A): a beni `foldl` written as a tail loop over `unsafeGet` is **1.0×**
the JavaScript loop on cow on every engine (the JIT inlines `a[i]`), and 3–5× on the trie at
10 000–100 000 (a descent per element); a beni `map` that builds a cons list and calls `fromList` is
1.0–1.2× a JavaScript `map` on cow and ~2× on the trie. Both stay O(n). A foreign leaf iterator for
the trie side, or `sync`-callback foreign folds once W8's `sync` parameters exist, would recover
the 3–5×; neither is needed for a first version.

```
-- core/Array.beni (sketch)
pub equatable foreign type Array a          -- plain JS array (≤ 1 024) or trie node

pub foreign empty : Array a
pub foreign length : Array a -> Int
foreign unsafeGet : Array a, Int -> a       -- not exported; bounds checked below
pub foreign set : Array a, Int, a -> Array a        -- out of range: unchanged (Elm)
pub foreign push : Array a, a -> Array a
pub foreign pop : Array a -> Array a                 -- Elm lacks it; §3 shows why it is wanted
pub foreign slice : Array a, Int, Int -> Array a     -- Elm's negative-index rules
pub foreign append : Array a, Array a -> Array a
pub foreign insertAt : Array a, Int, a -> Array a
pub foreign removeAt : Array a, Int -> Array a
pub foreign swap : Array a, Int, Int -> Array a
pub foreign fromList : List a -> Array a
pub foreign toList : Array a -> List a
pub foreign eq : Array a, Array a -> Bool       where a.eq : a, a -> Bool
pub foreign compare : Array a, Array a -> Order where a.compare : a, a -> Order
pub foreign sortWith… / sort : Array a -> Array a where a.compare : a, a -> Order

pub get : Array a, Int -> Maybe a
get arr i =
    if 0 <= i && i < length arr then Just (unsafeGet arr i) else Nothing

pub foldl : Array a, b, (a, b -> b) -> b       -- tail loop over unsafeGet
pub foldr, map, indexedMap, filter, initialize, repeat, isEmpty, toIndexedList, update, …
```

`eq`, `compare` and `sort` are foreign with a `where` clause, like `List.eq`/`List.compare`
today — the same shape CLAUDE.md flags as a surviving hazard for effects (a JS loop calling beni
evidence), and it should be tracked with them. `Array.js` holds: the copy helper (a loop below 64
elements, `concat()` above — §11's integer caveat is why), the trie's `get`/`setIn`/`pushLeaf`/
`popLeaf`/`fromArray`/`toArray`/leaf walk, and one `Array.isArray` dispatch per export, with the
identity-preserving no-ops of §7. The renderer's `For` over an `Array` receives the plain array
directly when it is one and walks the trie's leaves otherwise.

### 12.3 The API surface

Elm's `Array` API (`empty`, `initialize`, `repeat`, `fromList`, `isEmpty`, `length`, `get`, `set`,
`push`, `append`, `slice`, `toList`, `toIndexedList`, `map`, `indexedMap`, `foldl`, `foldr`,
`filter`), subject-first and uncurried as the rest of `core/` is (`Array.get arr i`), plus what §3 and
§5 show a UI needs and Elm makes users write badly: **`pop`, `insertAt`, `removeAt`, `swap`,
`update : Array a, Int, (a -> a) -> Array a`, `sortBy`/`sortWith`/`sort`, `find`/`findIndex`**, and
`eq`/`compare` through `where` like `List`. Documented guarantees: O(1) `length`; `get`/`set`/`push`
/`pop` O(1) up to 1 024 elements and O(log₃₂ n) above; the identities of §7.

### 12.4 Expected bundle cost

**≈1.1–1.5 KB brotli** for the sibling (measured upper bound 1.47 KB for the first-order hybrid),
plus the beni-written functions a program actually reaches, which DCE (`src/js/Reach.zig`) already
removes when unused. Against the alternatives: Elm's `Array` 1.5 KB, funkia 4.4 KB, Immutable.js
16.8 KB, mori 31.4 KB.

### 12.5 What this discharges

* `backend.md` §4's *"pending M3c's benchmark of a vector trie"* for **`List`**: keep cons cells
  (§9); the trie belongs to `Array`, above 1 024 elements.
* X2 in `plans/browser-platform.md` §3 and the representation half of W35.
* R29 §10.4's caveat: the copy-on-write array it measured is the right answer up to about a
  thousand elements and the wrong one above.

---

## 13. Reproducing

Scratch directory (not in the repo): `scratchpad/arrays/`.

* `impls/*.js` — one adapter per candidate; `cow.js`, `trie.js`, `hybrid.js` are the ports;
  `elm-raw.js` is `elm make --optimize` output of `elm/Main.elm` with the Array functions exported.
* `harness.js` — the timing loop, the operation table (`OPS`), `runJfb`; `liststyle.js` — §9, importing
  `beni-rel/ListStyle.mjs` built by `beni build --platform=node --library --release`;
  `typed.js` — §10; `mem.js` — §8 and the typed-array memory; `identity.mjs` — §7;
  `sizes.mjs` — §6; `test.mjs` — the differential test.
* `build.mjs` bundles one IIFE per candidate (`dist/`); `run.mjs <node|sm|bun|chrome> <bundle…>`
  runs them (Chrome through `puppeteer-core` against the system Chrome 153) and appends to
  `results/<engine>.jsonl`; `tables.mjs` renders every table in this report and its appendices.

---

## 14. Mutative (added 2026-09-29, Node only)

[Mutative](https://github.com/unadlib/mutative) 1.3.0 (the latest npm release; source read at
`af06787`, 2026-09-28) was asked for after the rest of this report was written. It is measured on
**Node 24.19 only**, in a batch that re-runs cow, the trie, hybrid 1024, Immer and the native
baseline on the same machine, so its figures are comparable with each other and **not** with the
Chrome tables of §3. Harness: `bench/arrays/mutative.mjs` (§14.6).

### 14.1 How it works on arrays (from the source)

`create(base, recipe, options)` wraps the array in a revocable `Proxy` whose target is a fresh
`Object.assign([], state)`, plus per-call bookkeeping (two `WeakSet`s, finaliser and revoke lists, a
spread of the options). **Nothing is copied at creation. On the first write through the draft (the
`set` or `deleteProperty` trap), `ensureShallowCopy` copies the whole array once with
`Array.prototype.concat.call(original)`**, and every later write in the same recipe goes into that
copy. So the result is a flat plain JavaScript array; the only sharing is of the untouched element
references. There is no trie, no chunking and no lazy copying below the whole array. A write of an
equal value (`Object.is`) is dropped, and a recipe that wrote nothing returns the base itself. **Reads
are also lazy, but they are not free**: reading an element that is itself draftable (a plain object,
array, `Map` or `Set`) through the draft makes the parent's shallow copy and wraps that element in a
child `Proxy`. So `const t = d[i]` inside a swap costs an O(n) copy and a proxy even before anything is
written. **Auto-freeze is off by default** (`enableAutoFreeze ?? false`, the reverse of Immer). When
it is on, `deepFreeze` walks the whole result after every `create`, which is O(n) per write even
though it skips the elements that are already frozen. **`mark`** is a classifier called on values the
draft meets. Returning `"immutable"` makes a class instance draftable, returning `"mutable"` means
"never draft this, hand it out raw", and returning a function gives a custom shallow copy. Batching
is simply many writes inside one recipe, or `create(base)` without a recipe, which returns
`[draft, finalize]`. There is no transient or persistent structure behind it. Two packaging facts
matter for a bundle. **The ESM entry (`exports.import` → `dist/mutative.esm.mjs`) is the development
build** (`__DEV__` compiled to `true`; `tsdown.config.mjs` builds no production ESM). The production
build exists only as CommonJS/UMD (`mutative.cjs.production.min.js`), which does not tree-shake.

### 14.2 Differential test

`node mutative.mjs test` runs 600 calls per candidate: 12 starting sizes from 0 to 33 000 and 50
random operations each, drawn from `set`, `push`, `pop`, `swap`, map (through a draft for
Immer/Mutative), `filter`, 100 sets in one draft, 100 separate sets, and an identity map through the
draft. After every call it compares the result element by element with a plain-array reference and
checks `get`, `foldl` and `eq`. It also checks that **the input is untouched**: the same length, the
same element objects and the same element contents as before the call. All three Mutative
configurations, Immer, cow, the trie and hybrid 1024 pass. The test also checks that default
Mutative does not freeze and that the freeze configuration does. Two harness-only failures came up
on the way, and neither can reach beni, which has no cyclic values. **A recipe that returns a new
value runs it through `handleReturnValue`, a recursive walk with no cycle check that overflows the
stack on cyclic records**, and the development build's `deepFreeze` throws `Forbids circular
reference` on them. The freeze configuration therefore uses the production build and freezes its
input through an empty recipe.

### 14.3 Timings

The four Mutative configurations:

* **Mutative default** is `create` with no options, imported as a bundler resolves
  `import { create } from 'mutative'`. That is the development ESM build, with no freeze.
* **Mutative prod** keeps the default options but uses the production build (`dist/mutative.cjs.production.min.js`).
  It is 10–20 % faster than the default on pure writes.
* **Mutative fast** adds `mark: (v, t) => Array.isArray(v) ? undefined : t.mutable` to the production
  build, with no freeze. The `mark` tells Mutative that elements are opaque values, which is exactly
  beni's contract, so reading `d[i]` returns the element instead of drafting it. This is the fastest
  honest configuration for any recipe that *reads* elements: it cuts `swap` by 1.8× and map-in-a-draft
  by 3×. On blind writes (`set`, `push`, the batches) it is anywhere from 15 % faster to 45 % slower than
  Mutative prod, because `mark` is consulted on every value the draft meets. The 45 % is the
  100-separate-`set`s case. **Mutative prod and Mutative fast are the
  fastest honest options.** Neither changes semantics for beni's use, and which of the two wins
  depends on whether the recipe reads.
* **Mutative freeze** is the production build with `enableAutoFreeze: true`, which is Immer parity.

Immer is run as in §1: production build, auto-freeze on (its default). Reads and bulk operations
(`get`, `map`, `filter`, `foldl`) of Immer and Mutative are cow's loops over the plain array they
return. Mutative has no read API, so those rows measure the *array it produces*. The rows differ
from cow only because a frozen array's reads are 3–6× slower in V8, as §0 item 5 found in Chrome.

Method: as in the rest of the report. Each candidate is its own `node --expose-gc` process over its
own esbuild IIFE, so its call sites are monomorphic. Every measurement has at least 25 ms of warm-up
and 7 samples of at least 10 ms each, and a full GC runs before each operation. The processes were
pinned to one core with `taskset -c 13` and run one after another. The whole batch ran **five
times**, and each cell is the **median of the five round medians**. Mutative prod was added
afterwards and run in five rounds of its own. Elements are `{k, o}` records, and the operations have
§3's shapes. Each cell also gives, in brackets, the multiple
of the mutable native array for the same operation and size. For the two "100 sets" rows that base is
100 in-place writes.


**n = 8**

| op | native mut | cow (port) | trie (port) | hybrid 1024 | Immer | Mutative default | Mutative prod | Mutative fast | Mutative freeze |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| get | 0.8 ns | 0.8 ns (1.0×) | 2.0 ns (2.5×) | 0.8 ns (1.0×) | 4.8 ns (6.1×) | 0.8 ns (1.0×) | 0.8 ns (1.0×) | 0.8 ns (1.0×) | 4.9 ns (6.2×) |
| set | 6.2 ns | 24 ns (3.8×) | 27 ns (4.4×) | 24 ns (3.8×) | 3.92 µs (630×) | 2.10 µs (338×) | 1.68 µs (271×) | 1.44 µs (232×) | 3.87 µs (623×) |
| push | 8.4 ns | 24 ns (2.8×) | 47 ns (5.6×) | 24 ns (2.8×) | 6.17 µs (731×) | 3.33 µs (395×) | 3.37 µs (399×) | 3.44 µs (407×) | 4.38 µs (519×) |
| pop | 5.8 ns | 27 ns (4.8×) | 33 ns (5.7×) | 28 ns (4.8×) | 5.51 µs (954×) | 2.58 µs (447×) | 2.50 µs (434×) | 2.26 µs (391×) | 3.86 µs (668×) |
| swap | 5.5 ns | 22 ns (4.1×) | 49 ns (9.0×) | 22 ns (4.1×) | 4.11 µs (747×) | 7.07 µs (1 286×) | 5.88 µs (1 069×) | 3.01 µs (547×) | 7.23 µs (1 314×) |
| map | 13 ns | 35 ns (2.7×) | 42 ns (3.2×) | 35 ns (2.7×) | 74 ns (5.7×) | 36 ns (2.7×) | 30 ns (2.3×) | 35 ns (2.7×) | 75 ns (5.8×) |
| map in a draft | — | — | — | — | 28.3 µs (2 175×) | 36.8 µs (2 834×) | 24.3 µs (1 874×) | 10.6 µs (818×) | 28.0 µs (2 152×) |
| filter | 34 ns | 34 ns (1.0×) | 56 ns (1.7×) | 34 ns (1.0×) | 65 ns (1.9×) | 30 ns (0.9×) | 29 ns (0.8×) | 34 ns (1.0×) | 65 ns (1.9×) |
| foldl | 10 ns | 10 ns (1.0×) | 10 ns (1.0×) | 10.0 ns (1.0×) | 41 ns (4.1×) | 10 ns (1.0×) | 9.9 ns (1.0×) | 10 ns (1.0×) | 41 ns (4.1×) |
| 100 sets, one draft ¹ | 127 ns | 101 ns (0.8×) | — | — | 42.3 µs (332×) | 43.3 µs (340×) | 43.0 µs (337×) | 51.9 µs (407×) | 44.5 µs (349×) |
| 100 sets, one call each | — | 1.84 µs (14×) | 2.20 µs (17×) | 1.83 µs (14×) | 270 µs (2 115×) | 140 µs (1 098×) | 114 µs (892×) | 164 µs (1 287×) | 297 µs (2 331×) |

**n = 1 000**

| op | native mut | cow (port) | trie (port) | hybrid 1024 | Immer | Mutative default | Mutative prod | Mutative fast | Mutative freeze |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| get | 0.8 ns | 0.8 ns (1.0×) | 5.0 ns (6.3×) | 2.5 ns (3.1×) | 5.6 ns (7.0×) | 0.8 ns (1.0×) | 0.8 ns (1.0×) | 0.8 ns (1.0×) | 5.6 ns (7.0×) |
| set | 7.3 ns | 265 ns (36×) | 63 ns (8.5×) | 267 ns (36×) | 88.4 µs (12 063×) | 2.15 µs (294×) | 1.91 µs (261×) | 1.93 µs (264×) | 28.8 µs (3 930×) |
| push | 8.2 ns | 386 ns (47×) | 41 ns (5.0×) | 389 ns (48×) | 92.7 µs (11 323×) | 3.31 µs (405×) | 2.68 µs (327×) | 3.16 µs (386×) | 31.6 µs (3 862×) |
| pop | 6.1 ns | 203 ns (33×) | 31 ns (5.1×) | 203 ns (33×) | 107 µs (17 651×) | 4.08 µs (672×) | 3.27 µs (538×) | 3.34 µs (550×) | 30.1 µs (4 958×) |
| swap | 6.9 ns | 207 ns (30×) | 84 ns (12×) | 205 ns (30×) | 108 µs (15 527×) | 6.12 µs (880×) | 5.05 µs (726×) | 2.86 µs (412×) | 31.1 µs (4 477×) |
| map | 1.21 µs | 2.87 µs (2.4×) | 2.73 µs (2.3×) | 2.90 µs (2.4×) | 8.20 µs (6.8×) | 3.11 µs (2.6×) | 3.02 µs (2.5×) | 3.15 µs (2.6×) | 8.21 µs (6.8×) |
| map in a draft | — | — | — | — | 2.41 ms (1 990×) | 2.93 ms (2 421×) | 2.98 ms (2 463×) | 973 µs (804×) | 3.18 ms (2 631×) |
| filter | 2.34 µs | 2.15 µs (0.9×) | 4.28 µs (1.8×) | 2.19 µs (0.9×) | 6.99 µs (3.0×) | 2.17 µs (0.9×) | 2.11 µs (0.9×) | 2.19 µs (0.9×) | 6.90 µs (2.9×) |
| foldl | 960 ns | 964 ns (1.0×) | 1.21 µs (1.3×) | 980 ns (1.0×) | 4.90 µs (5.1×) | 967 ns (1.0×) | 967 ns (1.0×) | 1.00 µs (1.0×) | 4.93 µs (5.1×) |
| 100 sets, one draft ¹ | 124 ns | 275 ns (2.2×) | — | — | 127 µs (1 027×) | 51.5 µs (415×) | 47.0 µs (379×) | 51.1 µs (411×) | 75.4 µs (607×) |
| 100 sets, one call each | — | 25.4 µs (205×) | 4.70 µs (38×) | 21.8 µs (175×) | 8.62 ms (69 468×) | 170 µs (1 373×) | 142 µs (1 144×) | 184 µs (1 486×) | 2.80 ms (22 530×) |

**n = 100 000**

| op | native mut | cow (port) | trie (port) | hybrid 1024 | Immer | Mutative default | Mutative prod | Mutative fast | Mutative freeze |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| get | 1.6 ns | 1.6 ns (1.0×) | 13 ns (8.4×) | 12 ns (7.9×) | 7.3 ns (4.7×) | 1.7 ns (1.1×) | 1.6 ns (1.0×) | 1.7 ns (1.1×) | 7.4 ns (4.7×) |
| set | 7.4 ns | 363 µs (48 817×) | 103 ns (14×) | 106 ns (14×) | 8.72 ms (1 172 539×) | 372 µs (50 081×) | 359 µs (48 306×) | 365 µs (49 086×) | 3.04 ms (408 822×) |
| push | 6.8 ns | 405 µs (59 195×) | 73 ns (11×) | 70 ns (10×) | 9.43 ms (1 379 956×) | 1.01 ms (147 915×) | 991 µs (144 945×) | 1.05 ms (153 475×) | 3.89 ms (569 568×) |
| pop | 6.0 ns | 368 µs (60 936×) | 31 ns (5.1×) | 32 ns (5.3×) | 10.5 ms (1 735 606×) | 338 µs (55 989×) | 316 µs (52 316×) | 324 µs (53 673×) | 3.05 ms (504 467×) |
| swap | 7.0 ns | 367 µs (52 573×) | 106 ns (15×) | 104 ns (15×) | 10.6 ms (1 521 147×) | 339 µs (48 659×) | 317 µs (45 462×) | 320 µs (45 864×) | 3.10 ms (443 728×) |
| map | 131 µs | 1.26 ms (9.7×) | 275 µs (2.1×) | 286 µs (2.2×) | 1.76 ms (13×) | 1.38 ms (11×) | 1.33 ms (10×) | 1.35 ms (10×) | 1.77 ms (14×) |
| map in a draft | — | — | — | — | 439 ms (3 366×) | 463 ms (3 551×) | 444 ms (3 401×) | 99.5 ms (763×) | 459 ms (3 520×) |
| filter | 683 µs | 703 µs (1.0×) | 788 µs (1.2×) | 1.10 ms (1.6×) | 1.07 ms (1.6×) | 594 µs (0.9×) | 573 µs (0.8×) | 595 µs (0.9×) | 1.06 ms (1.5×) |
| foldl | 122 µs | 122 µs (1.0×) | 141 µs (1.2×) | 144 µs (1.2×) | 509 µs (4.2×) | 123 µs (1.0×) | 121 µs (1.0×) | 119 µs (1.0×) | 513 µs (4.2×) |
| 100 sets, one draft ¹ | 133 ns | 350 µs (2 640×) | — | — | 9.01 ms (67 934×) | 424 µs (3 198×) | 415 µs (3 131×) | 412 µs (3 106×) | 2.99 ms (22 534×) |
| 100 sets, one call each | — | 36.8 ms (277 828×) | 8.81 µs (66×) | 8.91 µs (67×) | 888 ms (6 698 341×) | 36.5 ms (275 566×) | 35.7 ms (269 457×) | 37.3 ms (281 523×) | 287 ms (2 166 667×) |


¹ This row is 100 `set`s at 100 random indices (cycling over the 8 slots at n = 8) inside **one**
`create`/`produce`, which is the use Mutative is designed for. For the other columns it means:
native, 100 in-place writes; **cow, one copy followed by 100 writes into it**, which is the reference
for what a batch reduces to when the compiler can prove the intermediate arrays local (§9's "local
in-place building"). The trie and the hybrid have no batch form.

**Noise.** The machine was shared: other sessions' `zig` builds ran during the batch, with a load
average of 3–4.5 on 32 threads. Pinning kept each process on core 13 but could not keep other
processes off it. Within one run, the median cell's IQR is 2.3 % of its median, but the
90th-percentile cell's IQR is 59 %. Nearly all of those wide cells are Immer and Mutative writes,
whose Proxy, closure and `WeakSet` allocation puts a varying number of scavenges into each 10 ms
sample: Mutative's `set` at n = 8 ranged from 1.25 µs to 8.2 µs within one run. In one of the five
rounds, the default-Mutative process was 3–6× slower on *every* cell, including plain `foldl` and
`get` loops, which is contention, not Mutative. Taking the median of five rounds is what removes it.
Between rounds, the IQR of a cell's five round medians is 3 % of its median for the median cell and
18 % at the 90th percentile. The worst cells are the n = 8 Mutative writes and the hybrid's `set` at
100 000 (49–125 %). **Nothing below rests on a ratio smaller than 2×**, except where a claim is
explicitly about a small difference, such as prod against fast.

What the tables say:

1. **Mutative is copy-on-write with a proxy in front.** At n = 100 000, one `set` costs **372 µs**
   against cow's 363 µs, and `pop` and `swap` cost the same as cow's. The cost is the same O(n)
   `concat` copy, GC-bound under Node as §4.4 explains. The trie does the same `set` in 103 ns,
   **3 600× less**. `push` is worse than cow (1.0 ms against 405 µs), because a `push` through the
   draft grows the freshly copied array, which then reallocates.
2. **At UI sizes, the proxy is the cost.** At n = 1 000, a single write costs 1.9–6.1 µs, which is
   **7–30× cow** (203–386 ns) and **30–130× the trie**. At n = 8, where cow's write is 22–28 ns, it
   costs 1.4–7 µs, 60–320× cow. Each `create` pays about 1 µs of fixed cost before it copies
   anything: a tight loop of `create` with one assignment runs at 1.0 µs per call on a warm,
   monomorphic site. Recipes that *read* an element pay again for drafting it: default `swap` costs
   6.1 µs against `set`'s 2.2 µs.
3. **Batching helps only against Mutative's own single writes.** 100 sets in one draft cost
   **47–52 µs** at n = 1 000, 3× less than 100 separate `create` calls (142–184 µs). They still cost
   **2× cow's 100 separate full copies (25 µs)**, **10× the trie's 100 path copies (4.7 µs)**, and
   **190× a single copy followed by 100 writes (275 ns)**. The per-write trap costs about 0.45 µs
   whatever n is: 43 µs at n = 8, and about 45 µs of the 47 µs at n = 1 000. So batching wins over
   cow only once one array copy costs more than the traps, which on Node is from about 2 000
   elements up (interpolated between the measured sizes). At n = 100 000, the batch costs 415–424 µs, 87× less than cow's 100 copies (36.8 ms) but **47×
   the trie's 8.8 µs**.
4. **At n = 1 000 and above it is 20–40× faster than Immer, mostly because it does not freeze.**
   Default Mutative against Immer, both with their own defaults: `set` at n = 1 000 costs 2.2 µs
   against 88 µs, and at n = 100 000, 372 µs against 8.7 ms. At n = 8 the two are within 2× of each
   other, and Immer's `swap` is the faster one. With freezing turned on (Mutative freeze), Mutative is
   3× faster than Immer at n = 1 000 and 100 000 on single writes, and the same at n = 8. The frozen
   output also makes every later read slower: `get` 5.6 ns against 0.8 ns, `foldl` 5.1× native.
   §0 item 5 said the same in Chrome.
5. **Map through a draft is the worst case.** Assigning each element through the draft costs 2.9 ms at n = 1 000 (2 400× an in-place map, 1 000× cow's `map`) and
   463 ms at n = 100 000. With `mark`, it is 3× less, but still 340× cow. Reads and bulk operations on
   the *result* are cow's (`get`, `filter`, `foldl` at 1.0× native), because the result is a plain
   unfrozen array.

### 14.4 Bundle size

Measured by `node mutative.mjs size`: esbuild 0.28, `--minify`, tree-shaken, `platform: browser`,
`NODE_ENV=production`, brotli at quality 11. The "typical set" is §6's list without `fromCons` and
`toCons`, because the Mutative adapter has neither. Immer and cow were re-measured the same way, so
the three rows are comparable with one another. §6's figures used a larger set, which is why its
Immer row reads 4 389.

| bundle | min | gzip | **brotli** |
|---|--:|--:|--:|
| `create` from `'mutative'` (resolves to the ESM development build; tree-shaken) | 19 173 | 6 382 | **5 782** |
| `create` from the production build (CommonJS, not tree-shaken) | 20 458 | 6 966 | **6 315** |
| `create` built from source with `__DEV__ = false` (a lower bound no published file reaches) | 15 653 | 5 390 | **4 929** |
| `produce` from `'immer'` (production) | 9 284 | 3 809 | **3 511** |
| typical set: Mutative (ESM) + cow reads | 20 042 | 6 727 | **6 092** |
| typical set: Mutative (production) + cow reads | 21 368 | 7 291 | **6 613** |
| typical set: Immer + cow reads | 10 099 | 4 104 | **3 785** |
| typical set: cow (port) | 966 | 410 | **382** |

Next to §6: **Mutative's `create` alone is 5.8 KB brotli.** That is 15× the cow port's whole typical
set, 4× the hybrid's measured upper bound (1.47 KB), 1.7× Immer, and more than funkia's 4.4 KB. A
bundle cannot get the production build and tree-shaking at once, because the published ESM is the
development build. Even the source built with `__DEV__` off is 4.9 KB, because `create` reaches the
`Map`/`Set` draft handlers and patch generation whether or not a program uses them.

### 14.5 Field identity

`node mutative.mjs identity`, at 100 elements (§7 showed the answers do not depend on size):

| candidate | `set` of the identical value | `swap i i` | map in a draft, identity function | `create`, empty recipe | `create`, reads only | `create`, `d[i] = d[i]` | `create`, `push` then `pop` | ints, `d[i] =` same int | untouched elements |
|---|---|---|---|---|---|---|---|---|---|
| cow / trie / hybrid (ports) | **same** | **same** | n/a | — | — | — | — | — | same |
| Immer | same | same | same | — | — | — | — | — | same |
| Mutative (all four configurations) | **same** | **same** | **same** | **same** | **same** | **same** | new | **same** | same |

**Yes on both counts.** A `create` that changes nothing returns the base object itself, and so does
a `set` of an identical value (`Object.is`, so `NaN` and `-0` are handled). That holds even when the
recipe read elements and so paid for a copy, because the result is chosen by the `operated` flag,
not by whether a copy exists. A net no-op that did write, such as a `push` followed by a `pop`,
returns a new array with equal contents. The ports behave the same way, and Immer matches. Mutative
therefore meets W27's container identity exactly as well as the ports do, and no better.

### 14.6 Reproducing

`bench/arrays/` is the first part of this report's harness to live in the repository. It holds
`mutative.mjs` (the one script, with adapters, harness, test, identity, size and tables), `ports/`
(the cow, trie and hybrid ports of §1, copied unchanged from the scratch directory of §13),
`package.json` with `package-lock.json` (`mutative` 1.3.0, `immer` 11.1.18, `esbuild` 0.28.2), and
`results/node.jsonl`, the raw cells of the five rounds plus the five rounds of Mutative prod.

```sh
cd bench/arrays && npm ci
node mutative.mjs test && node mutative.mjs identity && node mutative.mjs size
for r in 1 2 3 4 5; do node mutative.mjs bench 13; done      # core 13, ~45 s per round
node mutative.mjs tables
```

### 14.7 Verdict for `core/Array`

**Mutative is not a candidate for `core/Array`, and it changes nothing in §12.** It is not a data
structure. It is an update API over plain arrays, and on arrays it is exactly the cow design of §1:
it makes one flat O(n) copy per `create` and shares nothing below the whole array. It adds about
1 µs of proxy set-up per call and about 0.45 µs per write through the draft. So it keeps cow's
large-array write cliff (372 µs per `set` at 100 000 on Node, 3 600× the trie). It is 7–30× slower
than cow at UI sizes. It costs 5–6 KB brotli against the hybrid's ~1.5 KB. Batching, its intended
use, loses to the plain cow port's 100 separate copies at 1 000 elements and to the trie at every
size. Its good properties are ones the ports already have: no-op identity, no freezing by default,
and plain-array reads at native speed.

The one idea in it worth keeping is already in this report. **"Many writes, one copy"** is what
makes Mutative's batch cheaper than its single writes, and the compiler can get that for free
without a proxy: 100 writes after one copy cost 275 ns at n = 1 000. That is §9's local in-place
building, and it applies to `Array` exactly as it does to an array-backed `List`. It would soften
cow's cliff for loops that build or update an array locally. It does nothing for a single `set` on
a large array that other code shares, and that is the case the hybrid's trie exists for.

---

## 15. An adaptive array, measured on programs (added 2026-09-29, Node only)

§3–§5 measure one operation at a time. This section asks the owner's follow-up question on whole
programs: **what if an array is a plain JS array until something writes to it, whatever its size?**
It measures that design, called *adaptive*, on six scenarios. Every scenario is **written in beni and
compiled by this repository's `beni`**, not written by hand as JavaScript. Node 24.19 only, so the
figures compare with each other and with §14, not with the Chrome tables of §3.

### 15.1 The adaptive design

`bench/arrays/ports/adaptive.js` has 80 lines over the §1 cow and trie ports.

* **Every array starts as a plain JS array, at any size.** Literals, `fromList`, `initialize`, a
  decoder's output, `map`, `filter`, `slice`, `sortWith` and `append` onto a plain array all
  return plain arrays. So does every operation that builds a fresh array anyway, even when its
  input was a trie.
* **The first single-element write to a plain array longer than the threshold T converts it.** That
  means `set`, `push`, `pop` or `swap`. The array becomes a trie in one O(n) build, and the write is
  applied there. Later writes to the result stay in the trie. A plain array of T elements or fewer
  is written copy-on-write, as cow is. **T is 32, 256 or 1 024.**
* **The old version stays valid**, because neither representation is ever mutated. The §7 no-ops
  keep their identity: a `set` of the identical value returns its input and never converts.
  Because of that, the differential test's `swap i i` and out-of-range `update` return
  `model.rows` itself for every candidate.
* **Reads cost one `Array.isArray` check.** A second build, **adaptive1024P**, is what a compiler
  that has *proven* an array plain would emit: a bare `a[i]` and `a.length`, with no check. It is
  applied only where that proof is honest (§15.3).

The representation is **not canonical for a length**: a 5 000-element array can be either plain or
a trie. `eq` compares across representations, and the renderer walks either one.

### 15.2 Method

**The code is beni's own output.** `bench/arrays/scenarios/Array.beni` is an experimental
`core/Array` shaped as §12.2 says: a first-order `foreign` sibling (`length`, `unsafeGet`, `set`,
`push`, `pop`, `slice`, `append`, `fromList`, `toList`, `sortWith`), with `get`, `update`, `foldl`,
`foldr`, `initialize`, `repeat`, `map`, `indexedMap` and `filter` written in beni over it. `node
scenarios.mjs build` copies `core/`, adds that module and compiles the seven scenario modules in
`bench/arrays/scenarios/src/` with `beni build --platform=node --library --core-root=…`. That is the
development build, whose names are readable; `--release` changes names and layout, not calls.

The compiled JavaScript is **byte-identical for every candidate**. Only `_core/Array.foreign.mjs`
changes: an esbuild plugin swaps in each candidate's sibling at bundle time, a re-export of the
port under the declared names. What is not beni is in `scenarios/harness.js`:

* the decoder's hand-over of the fresh JS array it built (`fromJs`, which adopts the array where the
  representation allows it);
* the DOM runtime's `For` walk. It has `platforms/browser/runtime.js`'s `forPosition` shape: one
  record per row, `i.x !== item` per row, and a `selected` check per row. It walks the plain array,
  or the trie's leaves, with no copy.
* scenario 6's JavaScript APIs;
* the timing loop.

Candidates: **cow**, **trie**, **hybrid1024** (§12's recommendation), **adaptive32**,
**adaptive256**, **adaptive1024** and **adaptive1024P**. The last runs only the two scenarios where
its proof holds.

**Differential test first.** `node scenarios.mjs test` runs every scenario once per candidate: 298
checks per candidate, digests of every intermediate array, and inputs checked unchanged afterwards.
All seven candidates agree. The test also caught a *dishonest* proof: the first version ran the
proven-plain life step on a board that the sparse ticks had turned into a trie, and it silently
produced a different board. **A wrong plainness proof is a wrong answer, not a slow one.**

Timing is §14's loop. At least 25 ms of warm-up, then 7 samples of at least 10 ms each (3 samples
when a call exceeds 400 ms, 1 when it exceeds 1.5 s), and a full GC before each cell. Each
candidate is its own `node --expose-gc` process over its own esbuild IIFE, pinned with `taskset
-c 13`. **Three rounds; each cell is the median of the three round medians.** The steady and first
rows are defined like this:

* **steady:** the state is threaded from call to call, so the array has already had many messages
  of that kind.
* **first:** every call starts from the same freshly created value. For adaptive this is the
  first-write conversion, paid on every call.

**Noise.** The machine was shared. The load average was 1.5–2.3 on 32 threads for two rounds and
rose to 15 during round 3's cow process. Within a run, the median cell's IQR is 2.3 % of its median.
Between rounds, the IQR of a cell's three medians is 2 % of the median for the median cell and 8 %
at the 90th percentile. The worst cells are sub-40 µs table cells at 1 000 rows (60–100 %).
**Nothing below rests on a difference under 1.3×** unless it says so. The cow cells at 100 000
elements are GC-bound under Node (§4.4) and would be smaller in Chrome.

### 15.3 What beni emits

Scenario 1's swap, as Elm's js-framework-benchmark implementation writes it, and core's `get` and
`foldl`, exactly as compiled (`dist/beni/Table.mjs`, `dist/beni/_core/Array.mjs`):

```js
// Table.beni:  Swap i j -> case Array.get model.rows i of Just a -> case Array.get model.rows j of
//                  Just b -> { model | rows = Array.set (Array.set model.rows i b) j a } …
case "Swap":
  {
    const i$5 = msg$1.a;
    const j$6 = msg$1.b;
    const $t$3 = Array$get(model$2.rows, i$5);
    if ($t$3.$ === "Just") {
      const a$7 = $t$3.a;
      const $t$4 = Array$get(model$2.rows, j$6);
      if ($t$4.$ === "Just") {
        const b$8 = $t$4.a;
        return { ...model$2, rows: Array$set(Array$set(model$2.rows, i$5, b$8), j$6, a$7) };
      } else {
        return model$2;
      }
    } else {
      return model$2;
    }
  }

// core: get, and foldl as the tail-call loop of backend.md §8
const Array$get = (arr$1, i$2) => 0 <= i$2 && i$2 < Array$length(arr$1) ? { $: "Just", a: Array$unsafeGet(arr$1, i$2) } : { $: "Nothing", a: null };
const Array$foldlHelp = (arr$1, $in$1, n$3, $in$3, func$5) => {
  Array$foldlHelp: while (true) {
    const i$2 = $in$1;
    const acc$4 = $in$3;
    if (i$2 >= n$3) {
      return acc$4;
    } else {
      $in$1 = Basics$add(i$2, 1);
      $in$3 = func$5(Array$unsafeGet(arr$1, i$2), acc$4);
      continue Array$foldlHelp;
    }
  }
};
```

`Array$unsafeGet` and `Array$length` are the sibling's exports, imported as module bindings. For
adaptive, `unsafeGet` is `(a, i) => (Array.isArray(a) ? a[i] : T.get(a, i))`. **The proven-plain
build** (`node scenarios.mjs build` writes it to `dist/beniP/` by a mechanical rewrite) gives core
a `$P` twin of every beni-written reader, with `Array$unsafeGet(a, i)` → `a[i]` and
`Array$length(a)` → `a.length`:

```js
const Array$get$P = (arr$1, i$2) => 0 <= i$2 && i$2 < arr$1.length ? { $: "Just", a: arr$1[i$2] } : { $: "Nothing", a: null };
```

It makes the proven modules call those twins. The proof is honest in exactly two places. In
`Decoded.beni` every array comes from the decoder, `filter`, `sortWith` or `slice`. In `Life.beni`
every generation comes from `initialize`. Neither is ever written.

### 15.4 Scenario 1: the TEA table

Research 29's rows (`{id, label}`) are held in the model as an `Array`. **1 000 rows** is R29's
benchmark and a typical UI list. **10 000** is a large grid or a log view. Every message is `update`
followed by one render walk, because every message renders. "update every 10th" is written as Elm's
JFB writes it, with `indexedMap`. "remove one" is `filter` by id, which is also Elm's JFB code. The
steady-state remove is paired with an `AddOne` (`push`) so that the length stays fixed.

| message (+ render) | n | cow | trie | hybrid1024 | adaptive32 | adaptive256 | adaptive1024 |
|---|--:|--:|--:|--:|--:|--:|--:|
| update one row, first | 1 000 | 3.12 µs | 3.65 µs | 3.21 µs | 4.60 µs | 4.51 µs | 3.19 µs |
| update one row, steady | 1 000 | 3.68 µs | 4.07 µs | 3.71 µs | 3.98 µs | 3.97 µs | 3.69 µs |
| update every 10th, steady | 1 000 | 27.0 µs | 34.1 µs | 27.5 µs | 32.0 µs | 30.7 µs | 25.3 µs |
| swap, first | 1 000 | 3.40 µs | 3.55 µs | 3.55 µs | 4.46 µs | 4.32 µs | 3.48 µs |
| swap, steady | 1 000 | 3.54 µs | 3.55 µs | 3.59 µs | 3.63 µs | 3.56 µs | 3.52 µs |
| remove one, first | 1 000 | 15.5 µs | 22.8 µs | 16.3 µs | 20.1 µs | 19.8 µs | 16.1 µs |
| remove one + add one, steady | 1 000 | 19.9 µs | 25.6 µs | 19.7 µs | 28.6 µs | 28.4 µs | 19.2 µs |
| append 1 000 | 1 000 | 36.0 µs | 49.3 µs | 53.8 µs | 38.0 µs | 38.3 µs | 37.4 µs |
| select (render only) | 1 000 | 2.81 µs | 3.41 µs | 2.97 µs | 2.89 µs | 2.87 µs | 2.86 µs |
| update one row, first | 10 000 | 32.0 µs | 34.0 µs | 37.6 µs | 45.9 µs | 42.5 µs | 41.5 µs |
| update one row, steady | 10 000 | 37.2 µs | 49.2 µs | 52.3 µs | 52.1 µs | 49.7 µs | 51.1 µs |
| update every 10th, steady | 10 000 | 242 µs | 321 µs | 393 µs | 261 µs | 247 µs | 281 µs |
| swap, first | 10 000 | 37.4 µs | 33.7 µs | 37.1 µs | 42.6 µs | 42.8 µs | 42.0 µs |
| swap, steady | 10 000 | 36.5 µs | 35.8 µs | 36.0 µs | 34.7 µs | 32.0 µs | 32.8 µs |
| remove one, first | 10 000 | 154 µs | 239 µs | 301 µs | 193 µs | 192 µs | 160 µs |
| remove one + add one, steady | 10 000 | 170 µs | 240 µs | 275 µs | 264 µs | 275 µs | 183 µs |
| append 1 000 | 10 000 | 67.6 µs | 78.3 µs | 79.3 µs | 68.1 µs | 69.2 µs | 67.2 µs |
| select (render only) | 10 000 | 29.0 µs | 36.7 µs | 36.8 µs | 30.5 µs | 29.9 µs | 29.2 µs |

**The render walk is the message.** `select` is nothing but the walk: 2.9 µs at 1 000 rows and
29–37 µs at 10 000. Every single-row message costs less than 2× that. Cow's O(n) copy of a
10 000-row array (≈5 µs under Node) disappears into a walk that visits every row anyway. Table
sizes therefore **do not separate the designs by more than 1.5×**. The differences that exist follow
the representation *the walk* sees:

* A trie walk costs 1.2–1.3× a plain walk (`select` at 10 000: 36.7 µs for trie and hybrid against
  29–30 µs for cow and adaptive).
* The trie candidates are slower wherever a message rebuilds the array with `filter` or
  `indexedMap`, which returns a trie for them and a plain array for adaptive. `remove one` at
  10 000 costs 301 µs for hybrid1024 and 160 µs for adaptive1024.

On this workload adaptive1024 equals cow at 1 000 rows, and at 10 000 rows it is **equal to or
faster than hybrid1024 on every message except the two first writes**, "update one row" and "swap"
(+10 % and +13 %, the conversion). The
low thresholds lose here: at 1 000 rows, adaptive32/256 pay the conversion on every first write
(+1.3 µs) and on every remove-then-add cycle (+9 µs), because `filter` returns a plain array and
the `push` after it converts again.

### 15.5 Scenario 2: decoded, read-only data

A JSON array of `{id, name, price, category}` records is decoded and then only read. **10 000** is
a product catalogue or a search result set; **100 000** is a large export, which is what makes
anyone reach for `Array`. `decode` is `JSON.parse` plus the record loop a compiled decoder runs
(report 34), ending in `fromJs`.

Two groupings are reported. **Mixed** columns are the candidate's full process, in which scenario 1
ran first, so the core read loops have already seen tries. **Alone** columns come from a process
that ran only this scenario, so the core read loops have only ever seen plain arrays.

| op | n | cow | trie | hybrid1024 | adaptive1024 mixed | adaptive1024 alone | adaptive1024P alone |
|---|--:|--:|--:|--:|--:|--:|--:|
| decode (parse + records + hand-over) | 10 000 | 3.14 ms | 3.38 ms | 3.37 ms | 3.04 ms | 3.64 ms | 3.66 ms |
| count by category (`foldl`) | 10 000 | 14.1 µs | 67.4 µs | 72.9 µs | 36.0 µs | 29.5 µs | **13.6 µs** |
| total price (`foldl`) | 10 000 | 81.7 µs | 134 µs | 167 µs | 90.9 µs | 84.7 µs | 82.7 µs |
| `filter` one category | 10 000 | 106 µs | 163 µs | 163 µs | 85.5 µs | 67.7 µs | 68.5 µs |
| `sortWith` price + `slice` 20 | 10 000 | 2.23 ms | 2.27 ms | 2.29 ms | 2.21 ms | 2.19 ms | 2.19 ms |
| 1 000 binary searches by `get` | 10 000 | 182 µs | 260 µs | 273 µs | 194 µs | 194 µs | 163 µs |
| a page of 50 by `get` | 10 000 | 280 ns | 425 ns | 493 ns | 325 ns | 300 ns | 281 ns |
| decode | 100 000 | 31.4 ms | 32.2 ms | 32.3 ms | 31.0 ms | 31.3 ms | 31.1 ms |
| count by category (`foldl`) | 100 000 | 676 µs | 1.22 ms | 1.26 ms | 804 µs | 789 µs | 674 µs |
| total price (`foldl`) | 100 000 | 811 µs | 1.39 ms | 1.38 ms | 852 µs | 1.18 ms | 823 µs |
| `filter` one category | 100 000 | 1.06 ms | 1.77 ms | 1.32 ms | 812 µs | 684 µs | 682 µs |
| `sortWith` + `slice` 20 | 100 000 | 29.3 ms | 30.8 ms | 31.1 ms | 30.0 ms | 30.3 ms | 30.0 ms |
| 1 000 binary searches | 100 000 | 281 µs | 449 µs | 458 µs | 308 µs | 292 µs | 271 µs |
| a page of 50 | 100 000 | 284 ns | 485 ns | 551 ns | 322 ns | 300 ns | 288 ns |

(The alone runs of cow, trie and hybrid are in the raw data. Isolation moves every candidate's
`filter` by 20–35 %: cow's to 69 µs and 686 µs, and trie's and hybrid's to 127 µs and 1.36–1.38 ms,
still 1.9–2× adaptive's alone figure. It moves cow's total at 100 000 to 1.02 ms. Every other row
moves by under 10 %.)

**This is where adaptive pays for itself.** hybrid1024 decodes 10 000 or more elements into a trie,
and then every read pays for the descent:

* the `foldl`s cost 1.5–2× adaptive's;
* `filter` 1.6–1.9×;
* the binary searches 1.4–1.5×.

Adaptive keeps the decoded array plain and reads within 1.0–1.2× of cow in the mixed process; its
`filter` is *faster* than cow's there. Decoding itself costs the same for every candidate: the
trie build is 2–7 % of the parse. The one mixed-process cell where adaptive is 2.6× cow, `count` at
10 000 (36 µs against 14 µs), comes from the read site being polymorphic, not from the check: the
same core `foldl` loop saw tries in scenario 1. Alone it is 29.5 µs, and proven plain it is 13.6 µs.

### 15.6 Scenario 3: a grid game

The board is stored flat. **100 × 100** is a typical board game or small simulation; **1 000 ×
1 000** is a pixel-scale automaton or paint canvas. There are two workloads:

* *Sparse ticks* (`Grid.beni`) change k cells per tick, reading each changed cell's eight
  neighbours through `get` first. k = 1 is a click; k = 100 is a falling-sand frame.
* *A life step* (`Life.beni`) rebuilds every cell with `initialize`, reading nine cells each. It is
  the dense case, and it is proven plain.

| op | cells | cow | trie | hybrid1024 | adaptive32 | adaptive256 | adaptive1024 | adaptive1024P |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| make (`initialize`) | 10 000 | 101 µs | 112 µs | 117 µs | 102 µs | 101 µs | 101 µs | 63.6 µs ¹ |
| tick k = 1, first | 10 000 | 5.66 µs | 242 ns | 248 ns | 8.97 µs | 8.87 µs | 8.91 µs | — |
| tick k = 1, steady | 10 000 | 4.99 µs | 259 ns | 270 ns | 312 ns | 316 ns | 293 ns | — |
| tick k = 100, first | 10 000 | 496 µs | 25.2 µs | 25.6 µs | 38.6 µs | 38.1 µs | 35.5 µs | — |
| tick k = 100, steady | 10 000 | 499 µs | 25.3 µs | 25.9 µs | 30.1 µs | 29.6 µs | 26.8 µs | — |
| life step | 10 000 | 1.14 ms | 1.51 ms | 1.52 ms | 1.28 ms | 1.25 ms | 1.27 ms | 1.15 ms |
| make | 1 000 000 | 35.7 ms | 41.0 ms | 56.5 ms | 36.3 ms | 36.1 ms | 36.0 ms | 32.6 ms ¹ |
| tick k = 1, first | 1 000 000 | 3.80 ms | 291 ns | 292 ns | 1.88 ms | 1.79 ms | 1.79 ms | — |
| tick k = 1, steady | 1 000 000 | 3.40 ms | 312 ns | 323 ns | 352 ns | 350 ns | 338 ns | — |
| tick k = 100, first | 1 000 000 | 384 ms | 33.7 µs | 34.2 µs | 1.99 ms | 1.95 ms | 1.96 ms | — |
| tick k = 100, steady | 1 000 000 | 378 ms | 36.5 µs | 36.8 µs | 41.1 µs | 41.1 µs | 37.0 µs | — |
| life step | 1 000 000 | 184 ms | 248 ms | 252 ms | 198 ms | 196 ms | 199 ms | 182 ms |

¹ The proven-plain `make` runs in a process that saw only plain arrays. It is not a proof effect:
`make` reads nothing.

Cow's cliff is the whole story of the sparse ticks: **378 ms per 100-cell tick** on a million cells
(Node) against 37 µs. Adaptive's steady ticks are the trie's to within 1.2×. Its **first tick pays
the conversion once: 8.9 µs at 10 000 cells and 1.8–2.0 ms at 1 000 000.** That is less than one
cow copy of the same array under Node (3.8 ms), and it is paid once per board, not per tick. The
life step, whose generations are never written, stays plain under adaptive and costs 1.25–1.3× less
than the trie or hybrid (199 ms against 248–252 ms). Proven plain, it matches cow (182 ms against
184 ms).

### 15.7 Scenario 4: building in a fold

Each array is built one element at a time inside a `List.foldl` or a tail loop. The sizes are
**1 000**, a result list or a lookup table, and **100 000**, a data-processing job.

* *collect*: a `push` per input.
* *histogram*: 100 000 samples counted into n buckets, each an `Array.update`.
* *coin change*: a DP table built by `push`, where each new entry reads four earlier ones.

| op | n | cow | trie | hybrid1024 | adaptive32 | adaptive256 | adaptive1024 |
|---|--:|--:|--:|--:|--:|--:|--:|
| collect by `push` | 1 000 | 320 µs | 43.0 µs | 324 µs | 43.3 µs | 69.3 µs | 319 µs |
| histogram of 100 000 samples | 1 000 | 45.7 ms | 5.86 ms | 46.0 ms | 6.07 ms | 6.15 ms | 46.5 ms |
| coin-change table | 1 000 | 332 µs | 70.5 µs | 342 µs | 84.0 µs | 105 µs | 347 µs |
| collect by `push` | 100 000 | **21.5 s** | 8.28 ms | 10.3 ms | 8.15 ms | 8.14 ms | 10.1 ms |
| histogram of 100 000 samples | 100 000 | **39.3 s** | 19.1 ms | 19.1 ms | 19.1 ms | 18.7 ms | 18.8 ms |
| coin-change table | 100 000 | **21.1 s** | 9.08 ms | 10.7 ms | 10.2 ms | 10.2 ms | 10.5 ms |

At 100 000, cow is **2 000× slower**: 21–39 seconds against about 10 ms. Every threshold removes
that cliff. **Below the threshold, the same cliff reappears at a smaller scale.** A 1 000-bucket
histogram is written 100 000 times while it stays under 1 024 elements, so hybrid1024 and
adaptive1024 copy 1 000 elements per write. That costs **46 ms, against 6 ms at T = 32 or 256**
(7.6×). Collecting 1 000 results costs 320 µs against 43–69 µs. The hybrid needed a high threshold
because below it reads were fast and above it they were not. Adaptive does not have that reason:
its reads stay plain until something writes.

### 15.8 Scenario 5: undo history

The history keeps the last 100 versions of a **10 000**-element array, and each edit changes one
cell (`History.beni`; `List.take 100` on every edit, the same for everyone). Retained bytes are
measured with `process.memoryUsage().heapUsed` after two full GCs, holding the history after 150
edits (101 versions). The elements are small integers, so the figure is the containers alone.

| | cow | trie | hybrid1024 | adaptive32 | adaptive256 | adaptive1024 |
|---|--:|--:|--:|--:|--:|--:|
| one edit, first (on the fresh plain array) | 4.74 µs | 101 ns | 108 ns | 8.61 µs | 8.66 µs | 8.64 µs |
| one edit, steady | 6.76 µs | 719 ns | 718 ns | 711 ns | 712 ns | 719 ns |
| 100 undos + a `foldl` of the result | 11.8 µs | 48.2 µs | 45.8 µs | 57.3 µs | 58.0 µs | 51.9 µs |
| retained: one version | 79 KB | 97 KB | 97 KB | 79 KB | 79 KB | 79 KB |
| retained: 101 versions | **7 900 KB** | 178 KB | 178 KB | 178 KB | 178 KB | 178 KB |

**This scenario measures the conversion directly: 8.6 µs for 10 000 elements, about 0.9 ns per
element.**
That is 1.8× one cow copy and 85× one trie `set`, paid once. After it, adaptive is the trie: the
same 0.72 µs per edit and the same 178 KB for 101 versions, against cow's 7.9 MB. The undo row is a
`foldl` over the current version, which is a trie for everything but cow, so cow reads it 4× faster.

### 15.9 Scenario 6: handing arrays to JavaScript

A decoded array is mapped to view rows (`Interop.lines`) and to prices (`Interop.prices`). That is
the **mapped** state: a fresh array that nothing has written, plain under cow and adaptive and a
trie under trie and hybrid above 1 024. The **edited** state is the same array after one `set`, and
at these sizes it is a trie under everything but cow. Three consumers read it:

* `JSON.stringify(toJs(a))`;
* `Math.max.apply(null, toJs(prices))`;
* an HTML list builder that walks the array as the runtime does, with no copy.

| op | n | cow | trie | hybrid1024 | adaptive1024 |
|---|--:|--:|--:|--:|--:|
| `toJs`, mapped | 10 000 | 4.9 ns | 13.5 µs | 13.2 µs | 4.8 ns |
| `toJs`, edited | 10 000 | 5.0 ns | 13.4 µs | 13.5 µs | 13.3 µs |
| `JSON.stringify`, mapped / edited | 10 000 | 1.12 / 1.11 ms | 1.09 / 1.10 ms | 1.08 / 1.08 ms | 1.06 / 1.06 ms |
| `Math.max`, mapped / edited | 10 000 | 21.9 / 21.4 µs | 36.6 / 36.1 µs | 37.3 / 37.2 µs | 20.6 / 35.9 µs |
| `toJs`, mapped | 100 000 | 4.8 ns | 437 µs | 431 µs | 5.1 ns |
| `toJs`, edited | 100 000 | 4.7 ns | 438 µs | 436 µs | 428 µs |
| `JSON.stringify`, mapped / edited | 100 000 | 11.3 / 11.3 ms | 11.6 / 11.7 ms | 11.5 / 11.4 ms | 10.9 / 11.5 ms |
| `Math.max`, mapped / edited | 100 000 | 217 / 215 µs | 662 / 664 µs | 666 / 661 µs | 211 / 660 µs |
| HTML list, mapped / edited | 100 000 | 12.2 / 12.2 ms | 11.9 / 11.9 ms | 11.9 / 12.1 ms | 11.6 / 11.8 ms |

`toJs` of a trie is 13 µs at 10 000 and 430–440 µs at 100 000. Under adaptive, **a mapped or
decoded array crosses into JavaScript for free**, as it does under cow, where hybrid pays the full
copy. An edited one pays the same as under hybrid. The consumer usually dwarfs the conversion,
though: `JSON.stringify` costs 25× the conversion, and a walker that goes through the leaves needs
no conversion at all. The conversion is the whole cost only for a consumer as cheap as `Math.max`,
where a trie is 3× slower at 100 000.

### 15.10 Bundle size

`node scenarios.mjs size` measures the whole sibling as `_core/Array.foreign.mjs` would ship it: the
ten foreign exports plus `fromJs`, `toJs` and the leaf walk. It uses esbuild `--minify` with
tree-shaking, then brotli 11.

| sibling | min | gzip | **brotli** |
|---|--:|--:|--:|
| cow | 1 147 | 563 | **536** |
| trie | 3 132 | 1 267 | **1 219** |
| hybrid1024 | 4 149 | 1 611 | **1 536** |
| adaptive1024 | 4 092 | 1 577 | **1 499** |

Adaptive and hybrid are the same size to within 40 bytes. Both are the cow and trie ports plus one
dispatch per export.

*Added 2026-09-30:* [research 40](40-array-sibling-under-brotli.md) takes the adaptive sibling
from 1 499 to **1 093** bytes by hand, with the same results and the same speed. A real
`--release` build of the seven scenarios cuts it to 901, and a program that never writes gets
452. The report also lists which of the techniques beni's compactor could apply itself.

### 15.11 Verdict

1. **Adaptive beats the hybrid where the hybrid was weakest, and ties it everywhere else.** On
   large arrays that are never written, adaptive stays plain and the hybrid is a trie. That covers
   decoded data, `map`/`filter`/`initialize` results and life generations. In those cases adaptive
   is **1.3–2× faster on reads and `filter`**, and **handing the array to JavaScript is free
   instead of 0.4 ms at 100 000**. On write-heavy arrays it *is* the trie after the first write,
   with the same steady-state times (338 ns against 323 ns per one-cell tick on a million cells,
   0.72 µs per history edit) and the same 178 KB for 101 versions. It is the same size (1.50 KB
   against 1.54 KB brotli). In the TEA table, the render walk dominates every message and all
   designs are within 1.5× of each other. There adaptive1024 is equal to cow at 1 000 rows, and at
   10 000 rows it is at least as fast as the hybrid on every message except the two first writes
   (within 13 %).
2. **The first write's conversion costs 0.9–2 ns per element**: 8.6 µs at 10 000 elements and
   1.8–2.0 ms at 1 000 000, paid once per array. That is 1.8× one cow copy at 10 000, and cheaper
   than one cow copy at 1 000 000 under Node. It is invisible in the table, behind the render walk.
   The pattern that pays it *repeatedly* is an O(n) rebuild (`filter`, `map`) followed by a write.
   The rebuild returns a plain array and the write converts it again. In the table's
   remove-then-add cycle that costs adaptive32/256 +9 µs at 1 000 rows.
3. **The threshold should drop.** The hybrid needed 1 024 because its trie slowed every read.
   Adaptive's reads stay plain until something writes, so a high threshold only prolongs cow's
   write cliff: a 1 000-bucket histogram costs 46 ms at T = 1 024 and 6 ms at T = 32 or 256.
   **T = 256 is the suggested setting.** It is within 1.6× of T = 32 on the 1 000-element builds
   (69 µs against 43 µs to collect) and equal to it on every other write scenario. Its cost is a few µs of extra conversion on first writes to 256–1 024-row tables and a
   1.2–1.5× trie walk on the ones that were written. Lists up to 256 rows, which are most UI
   lists, never convert.
4. **Proven-plain `a[i]` buys up to 2× on tight loops and little elsewhere.** A `foldl` whose body
   is one comparison goes from 29.5 µs to 13.6 µs at 10 000 (2.2×), and from 789 µs to 674 µs at
   100 000. Binary searches improve by 7–16 % and the life step by 8–9 %. `filter`, `sortWith`
   and anything that allocates do not move. Proven plain matches or beats cow in every cell measured. Most
   of the gain is removing a *polymorphic* read site: the one core loop is shared by the plain and
   trie arrays of a whole program, which is also why the mixed process costs 36 µs where the
   isolated one costs 29.5 µs. **It is an optimisation to add later, and only with a sound proof**:
   applied to an array that is not plain, it computes a wrong answer silently (§15.2). Nothing in
   the adaptive design depends on it.

**For §12:** adaptive, not the hybrid, is the better `core/Array`. It uses the same two ports, the
same sibling size and the same trie behaviour under writes. The recommendation there becomes:
*plain until the first single-element write to an array longer than 256 elements, the trie after
it, and every rebuilding operation returns a plain array.* One property of §12.1 changes: the
representation is no longer canonical for a length. So `eq` must compare across representations
(the port does), and the renderer must accept either form, as it already had to.

**Reproducing**, from `bench/arrays/` after `zig build` at the root and `npm ci`:

```sh
node scenarios.mjs build && node scenarios.mjs test && node scenarios.mjs size
for r in 1 2 3; do node scenarios.mjs bench 13; done         # ~5 min a round; cow is 3 of them
for r in 1 2 3; do node scenarios.mjs bench 13 cow:decoded trie:decoded hybrid1024:decoded \
  adaptive1024:decoded adaptive1024P:decoded; done
node scenarios.mjs tables                                    # from results/scenarios.jsonl
```

The scenarios are in `scenarios/src/*.beni`, the experimental `Array` in `scenarios/Array.{beni,js}`,
the driver in `scenarios/harness.js`, the port in `ports/adaptive.js`, and the raw cells of all
rounds in `results/scenarios.jsonl`.

---

## 16. One sequence type, or `List` and `Array`? (added 2026-09-30, Node only)

The owner's question: **does beni need both `List` (cons cells) and `Array`, or can one sequence
type serve?** PureScript, which also targets JavaScript, makes the JS array its primary sequence and
keeps a cons `List` in a library; Elm keeps both. §9 answered this from hand-emitted JavaScript. This
section answers it from **list code written the way Elm programmers write it, compiled by this
repository's `beni`**, beside §15's array scenarios, so both halves sit on one table. Node 24.19
only, like §14 and §15.

### 16.1 The candidates, and how the list syntax lowers for each

Each candidate runs the same beni source through the same beni-facing API (`core/List`'s names and
signatures). Only the representation behind it changes, and so does what `[]`, `x :: xs` and a
`x :: rest` pattern turn into.

| | representation | `[]` | `x :: xs` (construction) | `case s of [] ->` / `x :: rest ->` (matching) |
|---|---|---|---|---|
| **A** (two types, today) | `List`: a cons cell `{$: 1, a, b}` (beni's output, unchanged). `Array`: §15's adaptive array with T = 256 | `{$: 0, a: null, b: null}` | `List$cons(x, xs)`: one cell, O(1), shares `xs` | `s.$ === 0`; `s.a`, `s.b`: O(1) |
| **B** (one type) | §15's adaptive array (plain JS array, or the trie after the first write above 256 elements) **plus a view** `V {b, o, length}`: elements `o…` of a plain backing array | `$nil`, one shared `[]` | `$cons(x, xs)`: **a copy**, a fresh plain array of length(xs) + 1, O(n) | `$isNil(s)` is `s.length === 0`; `$hd(s)` is `b[o]`; `$tl(s)` is a new view `o + 1`, O(1) (the tail of a trie converts it to a plain array once) |
| **C** (one type) | B, plus the compiler rewrites of §16.3, applied by hand where a local rule licenses them | as B | as B, or a `push` into a builder the loop owns | as B, or `(array, offset)` locals with no view |
| **D** (one type) | funkia `list` 2.0.19, an RRB tree with prefix and suffix buffers, for `List` and `Array` alike | `L.empty()` | `L.prepend(x, xs)`: O(1) amortised, shares `xs` | `length === 0`; `L.first(s)`; `L.tail(s)` = `L.slice(1, n, s)` |

`core/List` is beni's compiled `core/List.beni` for A. For B and C it is `lists/core-single.js`, and
for D it is `lists/core-funkia.js`. Both are plain JavaScript loops, or funkia's own functions, with
the same names. A single-type core has to be written that way, because beni's `foldl`-then-`reverse`
over a copying `::` would be quadratic inside core itself. This favours B, C and D on the scenario 3
rows (§16.4): part of their lead on `List.map`, `foldr` and `reverse` is JavaScript against compiled
beni, not arrays against cells. §12.2's point stands: a real `core` must keep higher-order functions
in beni for effects, and §12.2 measured that at about 1.0× on plain arrays.

### 16.2 Method

* **Compiled by beni.** The four modules in `bench/arrays/lists/src/` (`Recur`, `Lib`, `Todo`,
  `Paths`), and §15's seven for the array half, are built with `beni build --platform=node --library`,
  the development build as in §15. beni already emits `::` as a call of `List$cons`. What it writes
  inline is the empty list, a literal's cells, the tag test `s.$ === 0|1` and the reads `s.a`/`s.b`
  of a subject it has just tested. `lists.mjs build` rewrites exactly those into `$nil`,
  `$cons(h, t)`, `$isNil`/`$isCons`, `$hd` and `$tl`, which is what a patched `js/Lower.zig`
  (`nilNode`, `consNode`, the `.list` arms of `fanDiscriminant`/`edgeKey`, `bindings` for
  `.pat_cons`/`.pat_list`) would emit. It recognises a list subject by its test, so a tuple's or a
  constructor's `.a` is left alone. It also fails the build if any list syntax survives.
* **The rewrite changes nothing but the representation.** Candidate **Ac** runs the rewritten code
  over `$` primitives that are cons cells again. It agrees with A on every check, and its time is
  **0.9–1.1× A in 90 % of its 130 cells** (median 1.01×). The worst cells are 1.8× (`pairwise`
  at 10 000), 2.3× (`sum` at 1 000) and 4.6× (`filter` with an accumulator at 100 000). So B, C and D carry at most that much of the lowering's own cost,
  and it counts against them.
* **Differential test first.** `node lists.mjs test` runs all 27 cells at sizes 0, 1, 2, 3, 10, 257
  and 1 000, twice each, threads a TEA model through 400 messages, and checks that inputs are
  unchanged. That is 197 checks per candidate, and **all five candidates agree**. `node
  scenarios.mjs test` (§15's 298 checks) passes with the two new array siblings, `single256` (B) and
  `funkia` (D).
* **Timing.** §15's loop: at least 25 ms of warm-up, then 7 samples of at least 10 ms each (3
  samples above 400 ms, 1 above 1.5 s). There is one `node --expose-gc --stack-size=4000
  --max-old-space-size=4096` process per (candidate, size), pinned with `taskset -c 13`, over 3
  rounds, and each cell is the median of the three round medians. An op that took more than 3 s per
  call at one size is not run at the next. A process that dies is restarted without the op that
  killed it, which is recorded as **OOM** (heap exhausted). A `RangeError` is recorded as **SO**
  (stack overflow).
* **Memory.** One process per (candidate, op, size). *Peak* is the resident high-water mark
  across one call, reset through `/proc/self/clear_refs` just before it, minus the resident size at
  that moment. *Retained* is the heap still used while the result is held, after two full GCs.
* **Noise.** The within-run IQR is 2.9 % of the median for the median cell. Between rounds, the
  range of a cell's three medians is 11 % of the median for the median cell and 42 % at the 90th
  percentile for n ≥ 1 000. One round of A at n = 10–100 ran under another session's load (load
  average 13) and was 5–10× slow; the median of three removes it. **Nothing below rests on a ratio
  under 1.5×.**

The list scenarios, in `lists/src/`:

1. *By hand* (`Recur.beni`): `map` and `filter` written as `f x :: mapRec rest f` (not a tail
   call), and again with an accumulator and a final `List.reverse`.
2. *`x :: rest` recursion*: `sum` (a tail loop), `takeWhile` (non-tail), `pairwise`
   (`(a, b) :: pairwise (b :: rest)`, which puts the matched `b` back on its tail), and merge sort:
   `split` deals alternately into two accumulators, and `merge` matches `( x :: xt, y :: yt )` and
   re-conses the head it did not take, as Elm code writes it.
3. *The library* (`Lib.beni`): `List.foldr` building a list, `foldr` summing, `range` + `sum`,
   `map2` as zip, `concatMap`, `acc ++ [ x ]` in a fold, `xs ++ ys`, `reverse`, `List.map`,
   `List.filter`.
4. *Prepending in a fold*: `List.foldl xs [] (\x acc -> x * 2 :: acc) |> List.reverse`; the same
   accumulator as a **field of the fold's state record**; two accumulators in a **tuple**, the way
   `List.partition` is written; and (`Paths.beni`) **retained lists that share tails**: the path to
   every node of a chain, `(i :: parent) :: paths`, all kept, as a search that remembers its paths
   does.
5. *A TEA model holding a `List`* (`Todo.beni`): `Add` prepends a record to `model.items`,
   `Remove id` is `List.filter`, and `Toggle id` is `List.map` updating one item. Every message is
   followed by the DOM runtime's positional render walk, as in §15.4.
6. *§15's array scenarios*, run again for A's `Array` (`adaptive256`), B's single type (`single256`,
   which is the same adaptive array plus the view dispatch) and D's (`funkia`). C is B there: none of
   its rewrites apply to array code.

### 16.3 Candidate C's rewrites, and the rules that license them

`lists/rewrites-c.js` replaces 12 compiled declarations by hand. Each one names its rule, and each
rule needs only the declaration, its module, or one fixed `core/List` function. None needs the
whole program:

* **R1, local builder.** A self-tail-recursive helper has a `List` parameter `acc`. If the helper
  is module-private, every call site outside the loop passes `[]`, and the loop uses `acc` only as
  the tail of one `e :: acc` feeding its own slot, or at an exit as `acc` / `List.reverse acc`, then
  `acc` is unique. It becomes a JS array the loop owns, stored back to front: `e :: acc` is
  `acc.push(e)`, and `List.reverse acc` is the array itself. `acc ++ [ e ]` is the same rule, stored
  front to back.
* **R2, tail recursion modulo cons.** In `e :: f rest` in return position, the self-call becomes a
  push into a fresh builder and a jump back to the loop head. No uniqueness proof is needed, because
  the builder is new. R2 is independent of the representation: it would also end the cons list's
  stack overflows in the table below.
* **R3, scalar view.** A loop's `List` parameter that is only matched, and whose tail flows only
  back into itself, is carried as (array, offset) locals.
* **R4, one core function inlined.** `List.foldl`/`List.foldr` with a literal lambda becomes core's
  loop at the call site, after which R1 may apply to the lambda's accumulator.
* **R5, re-cons of a match.** If the case just matched a value as `h :: t`, a later `h :: t` is
  that value.

The rules cover mapRec, filterRec, mapAcc, filterAcc, sum, takeWhile, pairwise, split, merge,
`foldr` building a list, `acc ++ [x]` and `x :: acc`. They leave three shapes alone:

* **The TEA model's list.** It lives in the model across messages and is shared with the previous
  model.
* **`recordFold` and `partitionFold`.** Proving their accumulators unique means tracking uniqueness
  through a record field or a tuple component. That is a uniqueness analysis over data, not a local
  rule.
* **`chainPaths`.** Its tails *are* shared, by every path that is kept, so no analysis could prove
  them unique.

### 16.4 The list scenarios

Node, median per call. The A column is absolute at n = 100 / 1 000 / 10 000 / 100 000. The other
columns are each candidate's time divided by A's at the same size. **Bold** marks ≥ 10×. **SO**
means stack overflow, and **OOM** means the process exhausted a 4 GB heap. Where A overflows and a
candidate does not, the candidate's absolute time is shown instead of a ratio. The n = 10 row is in
`results/lists.jsonl`. There, B is 0.3–9.4× A, C is 0.1–2.3× and D is 0.2–25×.

*1. By hand*

| code | A: 100 / 1 000 / 10 000 / 100 000 | B ÷ A | C ÷ A | D ÷ A |
|---|--:|--:|--:|--:|
| `f x :: mapRec rest f` | 758 ns / 8.06 µs / 150 µs / SO | **15** / **45** / **207** / SO | 0.6 / 0.5 / 0.2 / 1.66 ms | 8.8 / **11** / **11** / SO |
| `filterRec`, not a tail call | 258 ns / 3.95 µs / 53.5 µs / SO | 4.4 / **20** / **104** / SO | 0.6 / 0.4 / 0.4 / 782 µs | **18** / **11** / **12** / SO |
| map, accumulator + `reverse` | 561 ns / 6.96 µs / 100 µs / 5.31 ms | **17** / **34** / **259** / **4 355** | 0.5 / 0.4 / 0.3 / 0.3 | **12** / 9.0 / 6.7 / 1.9 |
| filter, accumulator + `reverse` | 224 ns / 4.86 µs / 39.9 µs / 510 µs | 5.0 / **15** / **131** / **7 470** | 0.6 / 0.3 / 0.6 / 1.3 | **20** / **10** / **13** / **12** |

*2. `x :: rest` recursion*

| code | A: 100 / 1 000 / 10 000 / 100 000 | B ÷ A | C ÷ A | D ÷ A |
|---|--:|--:|--:|--:|
| `sum` (tail loop) | 132 ns / 1.41 µs / 14.3 µs / 141 µs | 5.0 / 8.0 / 7.6 / 5.8 | 0.5 / 0.4 / 0.6 / 0.6 | **28** / **26** / **25** / **26** |
| `takeWhile` (keeps 90 %) | 579 ns / 7.96 µs / 93.4 µs / SO | **13** / **29** / **290** / SO | 0.5 / 0.3 / 0.3 / 1.59 ms | 8.3 / 6.3 / 6.6 / SO |
| `pairwise`, `(a, b) :: pairwise (b :: rest)` | 1.08 µs / 11.6 µs / 138 µs / SO | **15** / **105** / **2 301** / **OOM** | 0.5 / 0.5 / 0.5 / 3.55 ms | **19** / **19** / **19** / SO |
| merge sort (re-consing `merge`) | 8.17 µs / 165 µs / 2.39 ms / SO | 8.0 / **14** / **104** / **OOM** | 1.6 / 1.0 / 1.0 / 33.1 ms | **11** / 9.1 / 9.3 / SO |

*3. The library*

| code | A: 100 / 1 000 / 10 000 / 100 000 | B ÷ A | C ÷ A | D ÷ A |
|---|--:|--:|--:|--:|
| `List.foldr xs [] (\x acc -> x * 2 :: acc)` | 471 ns / 13.9 µs / 140 µs / 1.53 ms | **19** / **23** / **227** / **16 068** | 0.7 / 0.3 / 0.3 / 1.0 | 2.3 / 0.9 / 0.9 / 1.0 |
| `List.foldr` summing | 364 ns / 12.1 µs / 133 µs / 2.01 ms | 0.2 / 0.04 / 0.06 / 0.3 | 0.2 / 0.05 / 0.06 / 0.04 | 1.5 / 0.4 / 0.5 / 0.3 |
| `List.range` + `List.sum` | 373 ns / 8.04 µs / 85.8 µs / 921 µs | 0.8 / 0.5 / 0.4 / 1.6 | 0.8 / 0.5 / 0.4 / 1.6 | 2.9 / 1.3 / 1.3 / 1.3 |
| `List.map2` as zip | 761 ns / 12.2 µs / 136 µs / 1.68 ms | 0.6 / 0.5 / 0.4 / 1.0 | 0.7 / 0.5 / 0.4 / 1.0 | 1.7 / 1.0 / 0.9 / 0.7 |
| `List.concatMap` (`[x, x + 1]`) | 4.23 µs / 41.9 µs / 501 µs / 26.7 ms | 0.7 / 0.7 / 0.7 / 0.2 | 0.6 / 0.6 / 0.7 / 0.2 | 3.1 / 3.4 / 3.7 / 1.3 |
| `acc ++ [ x ]` in a fold | 23.8 µs / 3.02 ms / 302 ms / 107 s | 0.6 / 0.1 / 0.1 / 0.2 | 0.01 / 0.00 / 0.00 / 0.00 | 0.5 / 0.04 / 0.00 / 0.00 |
| `xs ++ ys` | 511 ns / 6.10 µs / 53.6 µs / 1.61 ms | 0.3 / 0.2 / 1.9 / 0.5 | 0.4 / 0.1 / 2.0 / 0.6 | 0.5 / 0.2 / 0.03 / 0.00 |
| `List.reverse` | 273 ns / 6.22 µs / 67.3 µs / 437 µs | 0.9 / 0.6 / 0.4 / 2.8 | 0.9 / 0.5 / 0.4 / 3.3 | 5.8 / 2.6 / 2.5 / 4.3 |
| `List.map` | 957 ns / 17.6 µs / 158 µs / 1.68 ms | 0.3 / 0.2 / 0.3 / 0.9 | 0.3 / 0.2 / 0.3 / 1.0 | 0.7 / 0.4 / 0.5 / 0.4 |
| `List.filter` | 468 ns / 12.1 µs / 145 µs / 1.45 ms | 0.5 / 0.6 / 0.7 / 0.7 | 0.6 / 0.6 / 0.8 / 0.8 | 2.4 / 0.9 / 1.0 / 1.0 |

*4. Building by prepending, and sharing tails*

| code | A: 100 / 1 000 / 10 000 / 100 000 | B ÷ A | C ÷ A | D ÷ A |
|---|--:|--:|--:|--:|
| `List.foldl xs [] (\x acc -> x * 2 :: acc)`, then `reverse` | 536 ns / 10.5 µs / 106 µs / 1.20 ms | **17** / **31** / **330** / **19 908** | 0.5 / 0.3 / 0.3 / 1.2 | 6.8 / 3.5 / 3.8 / 3.7 |
| the same accumulator as a record field, `{ st \| seen = x :: st.seen }` | 1.36 µs / 20.5 µs / 191 µs / 2.03 ms | 7.4 / **17** / **172** / **11 519** | 7.1 / **14** / **169** / **10 992** | 3.3 / 2.2 / 2.6 / 2.7 |
| two accumulators in a tuple (`partition`) | 786 ns / 16.5 µs / 156 µs / 1.49 ms | 8.5 / **13** / **104** / **8 189** | 7.2 / **12** / **105** / **7 744** | 2.1 / 1.1 / 1.3 / 1.8 |
| every path kept, `(i :: parent) :: paths` | 1.22 µs / 10.8 µs / 333 µs / 7.81 ms | **16** / **251** / **1 055** / **OOM** | **17** / **310** / **1 065** / **OOM** | 4.8 / 6.0 / 6.9 / 2.0 |

*5. A TEA model's list (each message + one render walk)*

| message | A: 100 / 1 000 / 10 000 / 100 000 | B ÷ A | C ÷ A | D ÷ A |
|---|--:|--:|--:|--:|
| `Add`, to the front, first | 518 ns / 8.18 µs / 79.1 µs / 1.43 ms | 1.2 / 1.0 / 1.0 / 1.4 | 1.3 / 1.0 / 1.1 / 1.2 | 2.4 / 1.6 / 1.5 / 1.5 |
| `Add` + `Remove` oldest, steady | 2.05 µs / 23.1 µs / 171 µs / 2.30 ms | 1.0 / 1.0 / 0.9 / 1.3 | 1.0 / 0.9 / 1.0 / 1.2 | 2.1 / 1.8 / 1.9 / 1.2 |
| `Toggle` one (`List.map`), steady | 1.43 µs / 18.8 µs / 173 µs / 2.25 ms | 0.9 / 0.9 / 0.8 / 1.1 | 0.7 / 0.9 / 0.8 / 1.1 | 1.3 / 1.0 / 1.0 / 0.8 |
| `Remove` one (`List.filter`), first | 1.47 µs / 19.3 µs / 171 µs / 2.73 ms | 0.8 / 0.9 / 0.8 / 1.1 | 0.5 / 0.8 / 0.8 / 1.0 | 2.3 / 1.7 / 2.0 / 1.2 |
| render only | 308 ns / 6.87 µs / 69.3 µs / 472 µs | 1.0 / 0.9 / 0.9 / 1.1 | 1.0 / 0.9 / 1.0 / 1.1 | 3.4 / 1.5 / 1.6 / 2.5 |

What the tables say:

1. **B alone is not viable.** Every `x :: xs` whose tail the loop does not own is an O(n) copy, so
   each of the ordinary shapes is O(n²): hand-written `map`/`filter`, accumulator-then-`reverse`,
   `takeWhile`, `foldr` building a list, prepending in a `foldl`. They cost 15–45× A at 1 000
   elements, 100–330× at 10 000 and 4 000–20 000× at 100 000, which is 4–24 s for one call. Two
   shapes also run out of memory. `pairwise` and merge sort re-cons the head they matched
   (`b :: rest`, `y :: yt`), so every stack frame holds its own fresh copy of the rest of the list,
   and live memory is O(n²). At 10 000 elements their peak is 390–480 MB (§16.6), and at 100 000
   they exhaust a 4 GB heap. Even the plain walk `sum`, which never builds, costs **5.8–8×** A,
   because every step allocates a view. In a GC'd target a view object costs about what a cons cell
   costs, but the cons list allocated its cells once, when the list was built.
2. **C is the fastest candidate wherever its rules reach.** It runs at 0.2–0.6× A on every
   by-hand and `x :: rest` shape, with no stack overflow at 100 000, where A overflows on five of
   them. At n = 10 merge sort is 1.6–2.3× A. The library rows are 0.04–1.0× A, except `reverse` and
   `range` at 100 000 (1.6–3.3×, Node's large-array copies, §4.4) and `xs ++ ys` at 10 000 (2×).
3. **C still has three O(n²) shapes, and the rules cannot reach them.** An accumulator kept in a
   **record field** or a **tuple** costs 12–14× A at 1 000, 105–169× at 10 000 and 7 700–11 000×
   at 100 000 (11–22 s). **Retained lists that share their tails** cost 310× A at 1 000 and
   1 065× at 10 000; they retain 382 MB where A retains 0.9 MB, and exhaust the heap at 100 000.
   All three are code Elm programmers write:
   * `List.partition` and `List.unzip` in `elm/core` are written with a tuple accumulator;
   * a fold whose state is a record is the usual way to carry more than one value;
   * `node :: pathSoFar` in a search, an undo stack of states, and a persistent stack all share
     tails by design.
4. **D has no cliff anywhere, but pays a constant factor everywhere.** Prepending is O(1), so
   nothing is quadratic and nothing runs out of memory. `acc ++ [x]` and `xs ++ ys` are O(log n)
   and beat A by up to four orders of magnitude, because A's `++` copies its left side. But funkia's
   `tail` is a `slice`, so a walk costs **25–28× A** (`sum`). The by-hand and `x :: rest` shapes cost
   6–20×, and the render walk 1.5–2.5×. It overflows the stack where A does, because R2 was not
   applied to it.
5. **The TEA list does not separate the candidates.** `Add` on a copying representation is an
   O(n) copy, but every message is followed by an O(n) render walk anyway. So B and C are within
   0.5–1.4× A on every message, and D within 0.8–3.4×. This is §15.4's result again: the walk is the
   message.

### 16.5 The array half: §15's scenarios under the single types

§15's harness, same method, 3 rounds, `RESULTS=results/single-scenarios.jsonl`. The baseline is A's
`Array` (adaptive, T = 256). Ratios are per cell.

| scenario (§15) | B (single256) ÷ A | D (funkia) ÷ A |
|---|--:|--:|
| TEA table, every message, 1 000 and 10 000 rows | 0.92–1.06×; 1.31× on `update every 10th`, first, and 1.38× on `remove one + add one`, steady, at 10 000 | 1.3–2.4×; 4.0× on `append 1000` at 1 000 |
| decoded data: decode, `foldl`, `filter`, sort, binary search, `get`, at 10 000 and 100 000 | 0.99–1.10× | 1.0–2.5× |
| grid: steady ticks, life step | 0.98–1.05× | 1.5–2.0× |
| grid: first tick (A converts to a trie once) | 0.97–1.01× | **0.00–0.05×** (no conversion) |
| build in a fold: `push` collect, coin table | 0.97–1.25× | 0.24–0.69× |
| build in a fold: histogram (`update`) | 1.04–1.05× | 2.5–3.2× |
| undo history: edit, first / steady / 100 undos | 1.05 / 1.02 / 1.26× | 0.03 / 1.22 / 1.08× |
| undo history: retained, 101 versions of 10 000 | 178 KB (1.0×) | 262 KB (1.5×) |
| interop: `toJs` of a mapped array, 10 000 / 100 000 | 5 → 7 ns (1.4×) | **84 µs / 2.0 ms** (O(n), against 5 ns) |
| interop: `Math.max.apply`, `JSON.stringify`, HTML list | 0.97–1.04× | 1.1–1.2× (JSON, HTML); 2.8–10× (`Math.max`) |

**B costs nothing on the array half.** The view check is one `instanceof` that never succeeds
here. All but four cells are within 1.11× of A; the four (the two table cells noted, the 100 undos,
and a 5 → 7 ns `toJs`) are within 1.38×. That is
expected: B's array *is* §15's adaptive array. **D is 1.2–2.5× slower on reads and walks**, and O(n)
at every interop boundary, where A hands over a plain array for free. It wins wherever A pays its
one-time trie conversion, and on building by `push`.

### 16.6 Memory

Peak is the resident growth during one call. Retained is the heap held by the result.

| code | n | A (cons) | B | C | D |
|---|--:|--:|--:|--:|--:|
| map, accumulator + `reverse` | 100 000 | 5.6 MB / 4.6 MB | **228 MB** / 1.6 MB | 2.3 MB / 0.9 MB | 20 MB / 1.1 MB |
| `x :: acc` in a fold | 100 000 | 5.4 MB / 4.6 MB | **211 MB** / 1.6 MB | 2.3 MB / 0.9 MB | 19 MB / 1.1 MB |
| into a record field | 100 000 | 2.4 MB / 4.6 MB | **232 MB** / 1.6 MB | **183 MB** / 1.6 MB | 16 MB / 1.1 MB |
| merge sort | 10 000 | 11 MB / 0.5 MB | **386 MB** / 0.1 MB | 6.7 MB / 0.2 MB | 17 MB / 0.2 MB |
| `pairwise` | 10 000 | 1.3 MB / 0.9 MB | **479 MB** / 0.5 MB | 0.4 MB / 0.5 MB | 14 MB / 0.6 MB |
| merge sort, `pairwise` | 100 000 | stack overflow | **heap exhausted (4 GB)** | 61 MB, 4.8 MB / 1.3, 4.7 MB | stack overflow |
| every path kept | 10 000 | 0.02 MB / **0.9 MB** | 498 MB / **382 MB** | 498 MB / **382 MB** | 1.5 MB / 1.2 MB |
| every path kept | 100 000 | 7.0 MB / 9.1 MB | heap exhausted | heap exhausted | 23 MB / 12 MB |
| TEA list, `Add` + `Remove`, steady | 100 000 | 5.3 MB / 4.6 MB | 3.1 MB / 0.9 MB | 3.1 MB / 0.9 MB | 0.5 MB / 1.4 MB |
| `List.map` | 100 000 | 2.0 MB / 4.6 MB | 2.3 MB / 0.9 MB | 2.4 MB / 0.9 MB | 0.02 MB / 1.0 MB |

Entries are peak / retained. A retained array is **5–6× smaller** than a cons list: 8–9 bytes an
element in Node against 46–48 (§8). Only the path case turns that around, because there each array
holds its own copy of what the cons lists share. It is the one scenario where a representation
choice changes *retained* memory by orders of magnitude (382 MB against 0.9 MB), not just the peak.

### 16.7 Bundle size

`node lists.mjs size`: esbuild `--minify`, tree-shaken, brotli 11. The surface is the twelve list
functions the scenarios reach plus the `$` primitives, and §15's Array sibling surface.

| runtime | min | gzip | **brotli** |
|---|--:|--:|--:|
| A: cons `List` (compiled `core/List` + `List.js`) | 1 213 | 541 | **515** |
| A: `Array` sibling (adaptive) | 3 723 | 1 448 | **1 377** |
| A: both | 4 959 | 1 913 | **1 801** |
| B: one runtime (`single.js` + list core) | 6 601 | 2 409 | **2 260** |
| C: B + builder helpers | 6 698 | 2 453 | **2 299** |
| D: one runtime (funkia + adapters) | 16 297 | 5 613 | **5 197** |

One type does not mean fewer bytes. B needs the adaptive array *and* the views, and hand-written
natives for every list function. D is 2.9× the two types together.

### 16.8 Verdict

Ratios to the two-type baseline A at n = 1 000 / 10 000. "×n²" means the ratio grows with n, i.e.
the op is quadratic.

| scenario | code shape | B ÷ A | C ÷ A | D ÷ A | catastrophic, and for whom |
|---|---|--:|--:|--:|---|
| 1 | `f x :: go rest` (map/filter by hand) | 20–45 / 104–207, ×n² | 0.4–0.5 / 0.2–0.4 | 11 / 11–12 | **B**: O(n²). A and D overflow the stack at 100 000 |
| 1 | accumulator + `List.reverse` | 15–34 / 131–259, ×n² | 0.3–0.4 / 0.3–0.6 | 9–10 / 7–13 | **B**: 4–23 s at 100 000 |
| 2 | `sum` walk | 8.0 / 7.6 | 0.4 / 0.6 | 26 / 25 | D is 25× on the most basic loop, but it is constant |
| 2 | `takeWhile` (non-tail) | 29 / 290, ×n² | 0.3 / 0.3 | 6.3 / 6.6 | **B** |
| 2 | `pairwise`: `(a, b) :: go (b :: rest)` | 105 / 2 301 | 0.5 / 0.5 | 19 / 19 | **B**: O(n²) time *and* live memory; 479 MB at 10 000, heap exhausted at 100 000 |
| 2 | merge sort, `merge` re-consing its heads | 14 / 104 | 1.0 / 1.0 | 9.1 / 9.3 | **B**: 386 MB at 10 000, heap exhausted at 100 000 |
| 3 | `foldr` building a list | 23 / 227, ×n² | 0.3 / 0.3 | 0.9 / 0.9 | **B** |
| 3 | `foldr` sum, `range`, `map2`, `concatMap`, `map`, `filter` | 0.04–0.7 / 0.06–0.7 | same | 0.4–3.4 / 0.5–3.7 | none |
| 3 | `acc ++ [x]` | 0.1 / 0.1 | 0.00 / 0.00 | 0.04 / 0.00 | none. **A** is the quadratic one here (107 s at 100 000) |
| 3 | `xs ++ ys`, `reverse` | 0.2–0.6 / 0.4–1.9 | 0.1–0.5 / 0.4–2.0 | 0.2–2.6 / 0.03–2.5 | none |
| 4 | `x :: acc` in a `foldl`, then `reverse` | 31 / 330, ×n² | 0.3 / 0.3 | 3.5 / 3.8 | **B** |
| 4 | accumulator in a **record field** | 17 / 172, ×n² | 14 / 169, ×n² | 2.2 / 2.6 | **B and C**: 22 s at 100 000 |
| 4 | accumulators in a **tuple** (`partition`) | 13 / 104, ×n² | 12 / 105, ×n² | 1.1 / 1.3 | **B and C**: 11 s at 100 000 |
| 4 | retained lists **sharing tails** (`node :: path`) | 251 / 1 055 | 310 / 1 065 | 6.0 / 6.9 | **B and C**: 382 MB retained at 10 000 (A: 0.9 MB), heap exhausted at 100 000 |
| 5 | TEA list: add to front, remove, toggle, render | 0.9–1.0 / 0.8–1.0 | 0.8–1.0 / 0.8–1.1 | 1.0–1.8 / 1.0–2.0 | none (the render walk dominates) |
| 6 | §15 arrays: reads, walks, writes, interop | 0.92–1.38 | = B | 1.2–4.0; `toJs` O(n) | none; D pays everywhere, most at interop |

**Would a programmer plausibly write the shapes that break?** For B, yes: every row marked B is
the textbook way to write Elm. For C, the three remaining shapes are less common than a plain fold,
but they are not exotic. `elm/core`'s own `partition` and `unzip` use tuple accumulators. A record
as fold state is how an Elm programmer carries two values. `node :: path` is how a search remembers
its route. An undo stack of states is W25's model history. A program that has one of these runs
correctly on small data and becomes 10 000× slower, or dies, on the data it meets in production.
Nothing in its source looks different from the code C handles well.

**Is a single type viable?**

* **B, never.** Copying `::` makes O(n²) the default for the most common list code.
* **C, only with a guarantee C cannot give.** Its local rules turn most list code into loops that
  beat cons cells by 2–5×. But a missed rule costs 10³–10⁴×, silently, and the rule set cannot be
  closed. Uniqueness through records and tuples would need a whole-function data-flow analysis.
  Retained shared tails are shared on purpose, so no static analysis makes them unique. Roc covers
  both cases with reference counts at run time (§9), and a garbage-collected JavaScript target has
  none. The honest guarantee would be "`x :: xs` is O(1) when the compiler can see that you own
  `xs`", and that is a performance contract depending on an optimiser, the thing §9 warned about.
  **A diagnostic could flag the misses**, and beni's rule says it must be a warning, not a refusal
  (CLAUDE.md rule 7). The flag would be *"`x :: acc` inside a loop or fold, where `acc` is not
  provably unique, copies the list"*, on every `::` that R1–R5 did not rewrite and that sits in a
  loop, a fold's lambda or a recursive function. It would fire on the TEA `Add` too, which is
  harmless (one copy per message, hidden by the render). It could not tell a program whose tails
  are shared on purpose how to fix it, except by switching to a type with O(1) prepend. That
  switch would be a second type again.
* **D is viable in the narrow sense.** It has no cliff, no O(n²) and no memory blow-up in any
  scenario, and it needs no compiler analysis. But its constant factor is paid everywhere: 25× on
  the simplest walk, 6–20× on `x :: rest` recursion, 1.2–2.5× on array reads, O(n) at every JS
  boundary where A is free, and 2.9× the bytes. A walk at 25× is not a frame-budget problem at UI
  sizes (36 µs for 1 000 elements), but it contradicts rule 8's premise that the runtime is not the
  limit.

**Recommendation: keep two types, as §9 concluded, now measured on beni's own output.** `List`
stays cons cells, because O(1) `::` for *any* tail is a guarantee the language can state without an
optimiser behind it. `Array` stays §15's adaptive array, and B's own measurements show it can carry
views at no cost to array code (0.92–1.10×) if slicing ever wants them. Two findings are worth
taking into beni independently of the verdict:

1. **R2 (tail recursion modulo cons) for the cons list.** A overflows the stack at 100 000 on five
   of the eight by-hand shapes (`map`, `filter`, `takeWhile`, `pairwise`, merge sort). C's loops show
   that the rewritten shape runs in O(n) with no stack. The rule is local and independent of the
   representation, and it removes a runtime failure (a stack overflow is an exception Elm
   programmers are promised not to see).
   *Taken 2026-09-30:* [`backend.md`](../backend.md) §8, *Tail calls modulo cons*, with a
   `run/` fixture for each of the five shapes.
2. **Native loops for `core/List`'s library functions.** B's and C's `List.foldr`, `map`, `map2`,
   `concatMap` and `reverse` run at 0.04–0.7× A up to 10 000 elements. The gain comes mostly from replacing compiled
   `foldl`-then-`reverse` with one loop, not from the array, so a cons-list core could take part of
   it. That was not measured here, and it has to respect §12.2's effects rule for higher-order
   functions.

### 16.9 Reproducing

From `bench/arrays/`, after `zig build` at the root and `npm ci` (which now installs funkia `list`
2.0.19 as well):

```sh
node lists.mjs build && node lists.mjs test && node scenarios.mjs test
for r in 1 2 3; do node lists.mjs bench 13; done            # ~16 min a round; A's `acc ++ [x]` at 100 000 is 3.5 of them
for r in 1 2 3; do RESULTS=results/single-scenarios.jsonl node scenarios.mjs bench 13 adaptive256 single256 funkia; done
node lists.mjs mem 13 && node lists.mjs size
node lists.mjs tables && node lists.mjs tables-arrays
```

The files:

* the scenarios, `lists/src/{Recur,Lib,Todo,Paths}.beni`;
* the list cores, `lists/core-{cons,single,funkia}.js`;
* B's single type, `ports/single.js`;
* D's Array port, `ports/funkia.js`;
* C's hand rewrites, `lists/rewrites-c.js`;
* the driver and the syntax rewrite, `lists.mjs`, with the harness in `lists/harness.js`;
* the raw cells, `results/lists.jsonl`, `results/lists-mem.jsonl` and
  `results/single-scenarios.jsonl`.

---

## 17. Array-first beni: one sequence type, on code written for it (added 2026-09-30, Node only)

§16 asked whether one sequence type could serve, and measured it on **Elm-shaped code**: `x :: acc`
then `List.reverse`, `f x :: go rest`, `(i :: parent) :: paths`. That code is shaped around cons
cells. Languages whose primary sequence is an array (JavaScript, Rust's `Vec`, Roc's `List`,
PureScript's `Array`) build at the **end**, with `push`, and never reverse. The owner's point: *"we
are hammering inefficient data structures when changing the code would be better."* This section
runs the fair test: **the same programs, written the way an array-first beni would write them**,
compiled by this repository's `beni`, against today's two types (A) on §16's own scenarios.
Only time, memory, stack safety and bytes are judged; how familiar the style is to an Elm
programmer is out of scope.

### 17.1 What array-first beni is

**One type, `List a`**, whose representation is §16's single type: §15's adaptive array (a plain
JS array until the first single-element write to one longer than 256 elements, the §1 trie after
it) plus the O(1) view `V {b, o, length}` that an `x :: rest` pattern makes. The syntax stays:

| syntax | array-first meaning | cost |
|---|---|---|
| `[]`, `[ a, b, c ]` | a plain array | O(length) |
| `case xs of [] ->` / `x :: rest ->` | the length test; the first element and a view one further on | O(1), one small object per match |
| `x :: xs` as an expression | a copy of `xs` with `x` in front | **O(n)** |
| `List.push xs x`, `List.pop xs`, `List.last xs`, `List.get xs i`, `List.set xs i x`, `List.slice xs a b` | the end is where a sequence grows | `get`, `last`: O(1), O(log₃₂ n) on the trie; `push`, `pop`: amortised O(1) with E1t's tail (§17.2); `set` below 256 elements and `slice`: a copy |

**The core, `lists/first-core/List.beni`, is beni over a first-order sibling**, as §12.2 requires:
a tail loop over `unsafeGet` for every higher-order function (`foldl`, `foldr` by a backwards
index, `map`, `indexedMap`, `filter`, `filterMap`, `concatMap`, `map2`–`map5`, `partition`,
`unzip`, `any`/`all`, `sortWith` as a merge of slices, `range`, `repeat`, `initialize`). The sibling
(`ports/first.js`) is first-order: `cons`, `eq`, `compare` (with `where`, as today), `length`,
`unsafeGet`, `set`, `push`, `pop`, `slice`, `append`, and **a core-private builder**: `builder`,
`add`, `done`. A builder is a fresh JS array that only the core loop which made it can see; `add`
pushes into it in place and returns it, and `done` hands it over as a plain `List`. It is the one
in-place write in the design, and it is sound because nothing outside `List.beni` can name a
`Builder` and every loop threads its builder linearly (each `add` result is the next call's
argument, so neither the release optimiser's dead-binding rule nor its single-use inlining can
drop or reorder one). It is what lets core build in O(n) with no cons list to reverse. A fiber that
suspends inside `map`'s callback resumes the same loop with the same builder; a multi-shot
continuation would need to copy it, and beni has none.

**The programs** (`lists/first/*.beni`) are §16's, rewritten as an array-first programmer writes
them: build with `List.push` at the end, never reverse, walk with `x :: rest` where recursion is
natural, and keep a stack's top at the end.

| §16 scenario | A: Elm-style (`lists/src/`) | array-first (`lists/first/`) |
|---|---|---|
| `map`/`filter` by hand | `f x :: mapRec rest f` | `x :: rest ->` loop, `List.push acc (f x)` |
| `map`/`filter`, accumulator | `f x :: acc`, then `List.reverse` | `List.foldl xs [] (\x acc -> List.push acc (f x))` |
| `sum` | `x :: rest` tail loop | unchanged (a view per step) |
| `sum` through the library (new) | `List.foldl xs 0 (\x acc -> acc + x)` | the same |
| `takeWhile` | `x :: takeWhile rest keep` (not a tail call) | `x :: rest` loop, `List.push acc x` |
| `pairwise` | `(a, b) :: pairwise (b :: rest)` | match `a :: rest`, then `b :: _` on `rest`; push `(a, b)`, recurse on `rest` as matched |
| merge sort | deal into two accumulators; `merge` re-conses the head it did not take | halves by `List.take`/`List.drop` (two slices); `merge` pushes the smaller head, ends with `acc ++ rest` |
| merge sort, sorted input (new) | the same on `[0, 1, …]` | the same |
| `foldr` building a list | `List.foldr xs [] (\x acc -> x * 2 :: acc)` | `List.foldl xs [] (\x acc -> List.push acc (x * 2))` |
| `acc ++ [ x ]` in a fold | as written | `List.push acc x` |
| `foldr` sum, `range` + `sum`, `map2`, `concatMap`, `xs ++ ys`, `reverse`, `List.map`, `List.filter` | as written | unchanged |
| `x :: acc` in a fold, then `reverse` | as written | `List.foldl` + `List.push` |
| accumulator in a record field | `{ st \| seen = x * 2 :: st.seen }`, then `reverse` | `{ st \| seen = List.push st.seen (x * 2) }` |
| accumulators in a tuple (`partition`) | `List.foldr` + `( x :: evens, odds )` | `List.foldl` + `( List.push evens x, odds )` |
| every path kept | `(i :: parent) :: paths` | `List.push paths (List.push parent i)`, `parent` from `List.last paths` |
| undo stack (new): 3 edits, 1 undo | `current :: history`; undo matches `previous :: older` | `List.push history current`; undo is `List.last` + `List.pop` |
| TEA `Add`, `Remove`, `Toggle` | `item :: model.items`, `List.filter`, `List.map` | `List.push model.items item`, the same two |

Two rows are new in both columns: `sum` through `List.foldl` (the walk an array-first programmer
reaches for first) and an undo stack, the persistent stack §16 named but did not measure. A merge
sort of sorted input is new too; it is the case where a `merge` holds one side unmatched for a
long run (§17.2).

### 17.2 The candidates

* **A** is today, as in §16: the cons `List` running the Elm-style sources, beni's output unchanged.
* **E1** is what the brief names: §16's single type (`ports/single.js`, adaptive T = 256 plus
  views), running the array-first sources over the array-first core. Its sibling `ports/first.js`
  adds the builder and one fix, below.
* **E1t** is E1 with a representation built for `push`, added because E1's own numbers (§17.4)
  show where it loses: `ports/first-tail.js`, one self-contained file of 250 lines, three changes.
  1. **A claimable trie tail.** A trie reads only its own `n` elements, so its tail array may hold
     elements past its end that belong to a newer version. `push` onto a version whose tail array
     ends exactly at its own end writes the element **in place** and returns a new header sharing
     the array; the element lands past every older version's end, so none of them can see it.
     `push` onto any other version (the second child of a shared path, a stack pushed after an
     undo) copies the at most 31 tail elements it owns first, never the whole sequence. `pop`
     shares the tail. A full tail moves into the tree as a leaf unchanged, and no leaf is ever
     written: an in-place push needs the tail array's length to equal the version's tail count,
     which is then below 32, and a leaf is 32 long. This is Go's `append` made persistent by each
     version's own length; it needs no compiler analysis, and no version can observe it.
  2. **`push` converts a plain array longer than 32 to the trie** (not 256); `set` and `pop` of a
     plain array keep §15.11's T = 256, so a read-mostly UI list stays plain.
  3. **A trie caches its plain copy** the first time a walk (`x :: rest`), `toJs` or a bulk
     operation needs one.
* **E1t256** is E1t with the push threshold left at 256, run to separate change 2 from change 1.
* **E2** (E1 plus a Scala-2.13-style front buffer) is **not built**. No array-first scenario
  prepends: in the compiled array-first output, `$cons` appears only in literals (`[ [ i ] ]` and
  `[ x, x + 1 ]`), because every program either pushes at the end or walks with a view. The one
  place a front insert is natural, a TEA list shown newest first, costs an O(n) copy per message
  that §16.4 measured at 1.0× A because the render walk is O(n) anyway. A front buffer would add
  bytes and a fourth form to every read for no scenario that uses it.

**One fix went into E1 before timing.** beni's decision tree binds every pattern variable of a
case branch before the branch runs, so `( x :: xt, y :: yt )` computes both tails even when only
one is used. §16's `single.js` makes the tail of a trie by converting the whole trie to a plain
array, so a `merge` that holds a trie side unmatched copies it on every step: O(n²). `ports/first.js`
caches that conversion per trie (a `WeakMap`), which makes the second `$tl` of the same trie O(1).
The array-first `merge` happened not to reach it, because `acc ++ rest` returns a plain array, but
any loop that matches a pushed-to (trie) sequence without advancing it would. A lowering that
binds a pattern's tail only on the branch that uses it would remove the hazard at its source.

### 17.3 Method

* **Compiled by beni.** `node lists.mjs build` compiles §16's sources for A as before, and the
  array-first sources with `--core-root` pointing at a copy of `core/` whose `List.beni` and
  `List.js` are replaced by `lists/first-core/`'s (the development build, as in §15 and §16). The
  whole E1 output, the compiled core `List` included, goes through §16's rewrite of the list
  syntax into `$nil`, `$cons`, `$isNil`, `$hd` and `$tl`, which is what a patched `js/Lower.zig`
  would emit. The bundler swaps `_core/List.foreign.mjs` and the list-syntax module for the
  candidate's port, and `++` for its `append`. E1, E1t and E1t256 run byte-identical compiled
  beni; only the port differs.
* **Differential test first.** `node lists.mjs test` runs all 30 cells at sizes 0, 1, 2, 3, 10,
  257 and 1 000, twice each, threads a TEA model through 400 messages and checks inputs unchanged:
  218 checks, and **A, Ac, B, C, E1, E1t and E1t256 agree on every one**. Three digests compare as sets,
  because the array-first programs keep a different order by design: a path root first and the
  paths oldest first, a new TEA row last, a stack's top last (the harness reads it top first
  under the array-first ports). `node scenarios.mjs test` (§15's 298 checks) passes with E1t's
  representation. **The claimable tail has its own persistence test**, `node lists/claim-test.mjs`:
  40 000 random `push`, `pop`, `set`, `append` and `$tl` operations on randomly chosen *old*
  versions (up to 3 000 alive, up to 9 759 elements, so tries two levels deep), and every live
  version compared element by element, by `unsafeGet` and by the runtime's walk against a
  plain-array model after every step: 2.39 million checks, all intact.
* **Timing** is §15's loop, in one `node --expose-gc --stack-size=4000` process per (candidate,
  size) running every op in turn, as §16 did, at 1 000, 10 000 and 100 000, pinned with
  `taskset -c 5`: another session's browser benchmark held cores 8–15 during this work, so §15's
  core 13 was not used. **Five rounds** at a load average of 3.7–4.6 (32 threads); each cell is
  the median of the five round medians. A's `acc ++ [ x ]` at 100 000 is §16's 107 s a call and
  was not run again.
* **A second pass, "alone"**, runs every (candidate, op, size) in a process of its own with a
  300 ms warm-up, three rounds, at a load of 5–20. It exists because the first pass showed that
  at 100 000 a cell's time depends on what ran before it in the process: A's `List.reverse` of
  100 000 takes 0.42 ms after 17 other ops have grown the young generation and 1.1 ms alone, and
  A's kept paths 1.6 ms against 2.7 ms. Where the two passes disagree, both are shown.
* **Noise.** Within a run the median cell's IQR is 4.6 % of its median (alone: 5.2 %). Between
  rounds, the range of a cell's round medians is 20 % of the median for the median cell and 71 %
  at the 90th percentile (alone: 31 % and 175 %, the load). **Nothing below rests on a ratio under
  1.5×.**

### 17.4 The list scenarios, written array-first

Node, median per call. The A column is absolute. The others are each candidate's time divided by
A's at the same size, in the same pass: *italic* is over 3×, **bold** 10× or more. Where A
overflows the stack (**SO**), the candidate's absolute time is shown. "Alone" divides E1t alone by
A alone.

*1. By hand*

| code | A: 1 000 / 10 000 / 100 000 | E1 ÷ A | E1t ÷ A | E1t ÷ A, alone | E1t256 ÷ A |
|---|--:|--:|--:|--:|--:|
| `map` by hand | 10.3 µs / 178 µs / SO | *8.3* / *5.6* / 6.95 ms | *3.7* / 1.9 / 4.72 ms | 2.7 / 2.5 / 2.92 ms | *6.5* / 2.1 / 5.01 ms |
| `filter` by hand | 5.83 µs / 64.2 µs / SO | **11** / *4.8* / 3.07 ms | *3.7* / 2.1 / 1.69 ms | *3.2* / *3.4* / 1.61 ms | *9.4* / 2.7 / 1.83 ms |
| `map` with an accumulator | 8.52 µs / 134 µs / 6.10 ms | *8.6* / *3.8* / 0.9 | 1.8 / 1.1 / 0.8 | 1.6 / 1.8 / 1.1 | *5.9* / 1.4 / 0.7 |
| `filter` with an accumulator | 5.08 µs / 44.1 µs / 547 µs | **10** / *6.4* / *4.7* | 2.6 / 2.8 / 2.4 | 1.6 / 2.0 / 1.0 | *9.5* / *3.9* / *3.1* |

*2. `x :: rest` recursion*

| code | A: 1 000 / 10 000 / 100 000 | E1 ÷ A | E1t ÷ A | E1t ÷ A, alone | E1t256 ÷ A |
|---|--:|--:|--:|--:|--:|
| `sum`, an `x :: rest` walk | 3.46 µs / 15.8 µs / 154 µs | *3.7* / *7.7* / *5.5* | *3.8* / *7.7* / *5.5* | *6.1* / *7.9* / *4.3* | *3.6* / *7.7* / *5.4* |
| `sum` by `List.foldl` (new) | 3.38 µs / 16.1 µs / 1.17 ms | 2.1 / *5.5* / 0.8 | 2.1 / *5.1* / 0.8 | 0.2 / *3.6* / 0.7 | 1.9 / *5.9* / 0.8 |
| `takeWhile` (keeps 90 %) | 8.38 µs / 108 µs / SO | *8.2* / *4.7* / 5.62 ms | 2.9 / 2.1 / 1.62 ms | 2.9 / 1.9 / 2.73 ms | *6.5* / 2.2 / 2.02 ms |
| `pairwise` | 12.6 µs / 132 µs / SO | *6.8* / *6.5* / 8.46 ms | 2.7 / 2.1 / 5.30 ms | 2.4 / 1.9 / 4.53 ms | *5.8* / 2.5 / 4.57 ms |
| merge sort | 166 µs / 3.00 ms / SO | *6.7* / *4.2* / 149 ms | *3.7* / 2.5 / 100 ms | *3.0* / 2.7 / 107 ms | **11** / *4.3* / 150 ms |
| merge sort, sorted input (new) | 132 µs / 2.19 ms / SO | *4.6* / *3.2* / 83.2 ms | *3.9* / 2.7 / 78.4 ms | 3.0 / 2.0 / 82.2 ms | *4.8* / *3.9* / 108 ms |

*3. The library*

| code | A: 1 000 / 10 000 / 100 000 | E1 ÷ A | E1t ÷ A | E1t ÷ A, alone | E1t256 ÷ A |
|---|--:|--:|--:|--:|--:|
| `foldr` building a list | 15.8 µs / 150 µs / 1.77 ms | *4.8* / *3.4* / *3.2* | 1.2 / 1.1 / 1.1 | 0.8 / 0.8 / 0.7 | *3.2* / 1.4 / 1.6 |
| `List.foldr` summing | 13.4 µs / 143 µs / 1.56 ms | 0.07 / 0.3 / 0.3 | 0.06 / 0.3 / 0.3 | 0.05 / 0.3 / 0.3 | 0.06 / 0.3 / 0.3 |
| `List.range` + `List.sum` | 7.93 µs / 91.5 µs / 1.01 ms | 2.0 / 2.0 / 2.8 | 1.2 / 1.7 / 2.8 | 1.3 / 1.2 / 2.1 | 1.1 / 1.7 / *3.1* |
| `List.map2` as zip | 13.0 µs / 149 µs / 1.85 ms | 1.3 / 1.1 / 1.4 | 1.1 / 1.0 / 1.4 | 0.8 / 0.8 / 0.3 | 1.1 / 1.0 / 1.6 |
| `List.concatMap` | 47.1 µs / 547 µs / 31.0 ms | 0.9 / 0.9 / 0.2 | 0.9 / 0.9 / 0.2 | 0.8 / 0.7 / 0.2 | 0.9 / 0.9 / 0.2 |
| `acc ++ [ x ]` in a fold | 3.39 ms / 341 ms / — | 0.02 / 0.00 / 5.66 ms | 0.00 / 0.00 / 1.93 ms | 0.00 / 0.00 / 2.14 ms | 0.02 / 0.00 / 2.73 ms |
| `xs ++ ys` | 8.75 µs / 63.3 µs / 2.20 ms | 0.1 / 1.6 / 0.4 | 0.1 / 1.5 / 0.4 | 0.1 / 1.5 / 0.4 | 0.1 / 1.5 / 0.4 |
| `List.reverse` | 7.32 µs / 79.5 µs / 421 µs | 1.7 / 1.4 / *5.3* | 1.5 / 1.3 / *5.3* | 1.5 / 1.1 / 2.3 | 1.5 / 1.3 / *5.4* |
| `List.map` | 20.5 µs / 169 µs / 1.79 ms | 0.7 / 0.8 / 1.4 | 0.6 / 0.8 / 1.4 | 0.8 / 0.6 / 1.1 | 0.6 / 0.8 / 1.5 |
| `List.filter` | 14.3 µs / 152 µs / 1.50 ms | 0.8 / 1.0 / 1.5 | 0.8 / 1.0 / 1.5 | 0.9 / 0.7 / 1.0 | 0.8 / 0.9 / 1.5 |

*4. Accumulating, and sharing*

| code | A: 1 000 / 10 000 / 100 000 | E1 ÷ A | E1t ÷ A | E1t ÷ A, alone | E1t256 ÷ A |
|---|--:|--:|--:|--:|--:|
| accumulator in a `foldl` | 11.6 µs / 120 µs / 1.30 ms | *6.3* / *4.2* / *4.5* | 1.5 / 1.4 / 2.3 | 1.1 / 1.1 / 0.9 | *5.6* / 1.7 / 1.9 |
| accumulator in a record field | 21.9 µs / 213 µs / 2.17 ms | *3.8* / 2.8 / *3.0* | 1.2 / 1.2 / 1.3 | 1.0 / 1.0 / 0.7 | *3.5* / 1.4 / 1.3 |
| accumulators in a tuple | 17.1 µs / 163 µs / 1.62 ms | *6.4* / *3.6* / *4.2* | 1.3 / 1.3 / 1.5 | 1.1 / 1.0 / 0.9 | *7.1* / 2.0 / 1.6 |
| every path kept | 11.6 µs / 147 µs / 1.61 ms | **18** / **13** / **41** | *4.5* / *5.4* / **17** | *4.8* / *4.1* / *5.4* | **15** / *4.8* / **16** |
| undo stack (new) | 10.7 µs / 131 µs / 1.45 ms | **11** / *5.3* / *6.0* | *3.8* / *3.5* / *4.2* | *3.9* / *3.3* / *3.2* | **13** / *4.2* / *4.2* |

*5. A TEA model's list (message + render walk)*

| code | A: 1 000 / 10 000 / 100 000 | E1 ÷ A | E1t ÷ A | E1t ÷ A, alone | E1t256 ÷ A |
|---|--:|--:|--:|--:|--:|
| `Add`, first | 8.57 µs / 85.5 µs / 1.55 ms | 1.0 / 1.0 / 1.2 | 1.0 / 1.0 / 1.1 | 1.0 / 0.9 / 0.9 | 1.0 / 1.0 / 1.2 |
| `Add` + `Remove` oldest, steady | 27.0 µs / 187 µs / 2.56 ms | 1.5 / 1.7 / 1.8 | 1.3 / 1.7 / 1.7 | 1.3 / 1.4 / 1.2 | 1.5 / 1.7 / 1.8 |
| `Toggle` one, steady | 20.3 µs / 201 µs / 2.43 ms | 1.3 / 1.2 / 1.5 | 1.3 / 1.2 / 1.4 | 0.9 / 0.7 / 1.0 | 1.2 / 1.2 / 1.5 |
| `Remove` one, first | 21.7 µs / 208 µs / 2.92 ms | 1.3 / 1.1 / 1.4 | 1.2 / 1.2 / 1.3 | 0.7 / 0.8 / 1.1 | 1.2 / 1.2 / 1.4 |
| render only | 8.25 µs / 82.6 µs / 525 µs | 0.7 / 0.6 / 0.9 | 0.6 / 0.6 / 1.0 | 0.6 / 0.5 / 0.6 | 0.6 / 0.6 / 1.0 |

What the tables say:

1. **E1, the representation the brief names, is not viable, and the code is not the reason.**
   Written array-first, nothing is quadratic any more: every row that was O(n²) for §16's B is
   linear. But **every row that builds with `push` costs 2.8–11× A at 1 000 and 10 000**: `map`
   and `filter` by hand and by accumulator, `takeWhile`, `pairwise`, merge sort, the
   order-keeping fold, and the accumulator in a `foldl`, a record field or a tuple. 17 of the 30
   rows go over 3× at some size. Kept paths cost 13–41× and the undo stack 5–11×. The cost is
   §15's persistent `push` itself: below 256 elements every push copies the array (building 256
   elements copies 32 896), and above it every push copies the trie's tail (16 elements on
   average) and allocates a header. A cons cell is one allocation.
2. **E1t removes that cost.** The claimable tail makes a push that extends the newest version one
   in-place write and one header, about what a cons cell costs, and the push threshold of 32
   removes the copying below 256. The accumulator rows fall to **0.8–2.9× A**: in a `foldl`, a
   record field or a tuple 1.2–2.3× (alone 0.7–1.1×), `map` and `filter` with an accumulator
   0.8–2.8×, `takeWhile` and `pairwise` 1.9–2.9×, `foldr` building a list and `acc ++ [ x ]`
   0.7–1.2×. The two changes act at different sizes, as E1t256 shows: at 1 000 the threshold is
   what matters (E1t256 is still 3.2–9.5× on the accumulator rows), at 100 000 the claimable tail
   is (E1 3.0–4.5×, E1t256 1.3–1.9× on the fold, record and tuple rows).
3. **The library rows need no change of code and do not separate the candidates.** `List.foldr`
   summing is 0.05–0.3× A, because it runs backwards over the array instead of reversing a list;
   `concatMap` 0.2–0.9×; `List.map`, `List.filter`, `map2` and `xs ++ ys` 0.1–1.6×. The two
   100 000 cells over 2× in the first pass, `List.reverse` (5.3×) and `range` + `sum` (2.8×), are
   A's process state: alone they are 2.3× and 2.1×.
4. **Four shapes stay near or above 3× under E1t, all constant factors, none growing with n:**
   * **A pure `x :: rest` walk** (`sum`): 3.8–7.9×. Each step allocates a view, where the cons
     list's cells already exist: 1 000 elements cost 13 µs against 3.5 µs. The walk an
     array-first programmer writes first, `List.foldl`, is 0.2–2.1× A at 1 000 and 100 000 and
     3.6–5.9× at 10 000 in both passes. That cell follows V8's tiering and the heap, not the
     representation: per element, A's fold runs at 1.6–12 ns and E1t's at 0.9–9 ns across the
     three sizes and two passes, with no trend in n. §16.3's rule R3, the scalar view, removes the
     allocation from a loop whose tail only feeds itself; it is a local rule and applies unchanged.
   * **Kept paths that share a prefix**: 4.1–5.4× in both passes up to 10 000 and alone at
     100 000; 17× in the first pass at 100 000 (27 ms against 1.6 ms, A's best case). Every path
     is a trie header, and one path in 32 copies a root-to-leaf path of nodes, where A's path is
     one cons cell. Nothing is quadratic, and retained memory is 1.1–1.4× A (§17.6).
   * **An undo stack**: 3.2–4.2×. An undo is `List.last` (a `Just`) and `List.pop` (a header), and
     the next edit copies the at most 31 tail elements the popped version shares with the one it
     came from. A's undo is one pattern match.
   * **`map` and `filter` by hand**: 1.9–3.7× at 1 000 and 10 000, a view per step plus a push;
     the library versions of the same functions are 0.6–1.0×.

   Merge sort sits at 2.0–3.9× (3.0× alone at 1 000) and completes at 100 000 in 78–107 ms,
   where A overflows.
5. **The TEA list does not separate the candidates**, as in §16.4: every message is 0.5–1.7× A
   under E1t, because the render walk visits every row anyway. Appending a row with `push` is
   0.9–1.1× A's prepend.


### 17.5 Stack safety at 100 000

`node lists.mjs stack` runs every op once at n = 100 000 on **Node's default stack** (no
`--stack-size`), one process per candidate. **A overflows in six ops**, the five shapes §16 named
(`map` and `filter` by hand, `takeWhile`, `pairwise`, merge sort) and merge sort of sorted input.
**E1 and E1t complete every op.** Nothing in the array-first sources or the array-first core
recurses except merge sort's two halves, whose depth is log₂ n: every loop is a self tail call,
which beni turns into `while (true)` (backend.md §8), and every result is built by `push` or a
builder, never by a pending `::` in a stack frame. The array-first style is stack-safe by
construction; A needs §16's rule R2 to become so.

### 17.6 Memory

One process per (candidate, op, size), §16.2's method: *peak* is the resident growth during one
call, *retained* the heap still held by the result after two full GCs. All 30 ops at all three
sizes are in `results/first-mem.jsonl`; the rows that build or keep something:

| code | n | A peak / retained | E1 peak / retained | E1t peak / retained |
|---|--:|--:|--:|--:|
| `map` by hand | 100 000 | stack overflow | 39.1 MB / 1.8 MB | 13.5 MB / 1.3 MB |
| `map` with an accumulator | 100 000 | 5.5 MB / 4.6 MB | 38.4 MB / 1.8 MB | 8.8 MB / 1.3 MB |
| accumulator in a `foldl` | 100 000 | 9.1 MB / 4.6 MB | 38.7 MB / 1.7 MB | 8.8 MB / 1.3 MB |
| accumulator in a record field | 100 000 | 8.8 MB / 4.6 MB | 38.9 MB / 1.8 MB | 12.3 MB / 1.3 MB |
| accumulators in a tuple | 100 000 | 6.5 MB / 4.6 MB | 24.2 MB / 1.8 MB | 12.3 MB / 1.3 MB |
| `pairwise` | 10 000 | 1.3 MB / 851 KB | 4.4 MB / 606 KB | 1.7 MB / 557 KB |
| `pairwise` | 100 000 | stack overflow | 42.8 MB / 5.6 MB | 15.6 MB / 5.2 MB |
| merge sort | 10 000 | 11.3 MB / 475 KB | 7.3 MB / 151 KB | 7.6 MB / 287 KB |
| merge sort | 100 000 | stack overflow | 61.5 MB / 877 KB | 58.4 MB / 1.7 MB |
| every path kept | 1 000 | 1.0 MB / 85 KB | 3.3 MB / 679 KB | 1.0 MB / 115 KB |
| every path kept | 10 000 | 28 KB / 929 KB | 10.2 MB / 4.5 MB | 2.3 MB / 1.1 MB |
| every path kept | 100 000 | 13.7 MB / 9.1 MB | 101 MB / **44.1 MB** | 23.3 MB / 10.5 MB |
| undo stack | 100 000 | 4.2 MB / 2.3 MB | 39.3 MB / 946 KB | 18.7 MB / 920 KB |
| `List.map` | 100 000 | 9.2 MB / 4.6 MB | 2.3 MB / 887 KB | 2.3 MB / 887 KB |
| `List.concatMap` | 100 000 | 42.5 MB / 9.2 MB | 9.9 MB / 2.0 MB | 15.6 MB / 2.0 MB |
| TEA `Add` + `Remove`, steady | 100 000 | 5.2 MB / 4.6 MB | 2.6 MB / 903 KB | 2.6 MB / 905 KB |

* **Retained**: a plain array holds a result in about 0.2× A's bytes (§16.6's 8–9 bytes an
  element against 46–48), a trie built by `push` in 0.3×, and tuples, whose size is the tuple's
  rather than the cell's, in 0.6–0.65× (`pairwise`, merge sort at 10 000). The one exception is
  the kept paths, where each version is a header: E1t retains 1.1–1.4× A, **E1 4.8×** (44 MB at
  100 000), because every E1 push onto a path copies its tail.
* **Peak** (the resident high-water mark, so a cell whose heap already had room reads near zero,
  as several of A's do at 10 000): E1's push-built results pass through 24–43 MB of copied tails
  at 100 000, 4–7× A. E1t's peaks at 100 000 are 1.0–1.9× A's, except the undo stack (18.7 MB
  against 4.2 MB, 4.5×: the tail copies after each undo, and a `Just` and a header per step) and
  merge sort, which A cannot run.
* **No memory blow-up for E1 or E1t.** Nothing here is §16's O(n²) live memory: the largest peak
  is merge sort's 58–62 MB at 100 000, O(n log n) of short-lived halves.

### 17.7 The array half: §15's scenarios on E1t's representation

§16.5 ran §15's array scenarios on §16's single type; E1 is that type (its port differs only in a
`$tl` cache those scenarios never reach), so its array half is §16.5's B column, 0.92–1.38× A's
`Array`. E1t's representation is new, so `node scenarios.mjs bench` ran it (`firsttail`,
`ports/first-tail-array.js`, whose `toJs` does not use the trie's cached copy, so the interop
cells measure a conversion) against A's `Array` (`adaptive256`) and `single256`, three rounds on
core 5. §15's differential test (298 checks) passes for all three.

| scenario (§15) | single256 (E1) ÷ A | firsttail (E1t) ÷ A |
|---|--:|--:|
| TEA table, every message, 1 000 and 10 000 rows | 0.94–1.28×; 1.49–1.75× on `update every 10th` at 10 000 | 0.92–1.29× |
| decoded data: decode, `foldl`, `filter`, sort, binary search, `get`; 10 000 and 100 000 | 1.03–1.19×; 1.55× on `total` at 10 000 | 0.94–1.04× |
| grid: make, ticks, life step; 10 000 and 1 000 000 cells | 0.68–1.14× | 0.71–1.04× |
| build in a fold: collect by `push`, coin table | 0.75–0.90× | **0.23–0.54×** |
| build in a fold: histogram (`update`) | 0.81–0.85× | 0.83–1.01× |
| undo history: edit first / steady / 100 undos | 0.75 / 0.79 / 1.40× | 0.76 / 0.78 / 0.59× |
| interop: `toJs`, `JSON.stringify`, `Math.max`, HTML list | 0.68–1.09× | 0.70–0.92× |

**E1t costs nothing on the array half and halves its push-built scenarios** (collecting 1 000
elements by `push`: 22 µs against 96 µs; 100 000: 6.4 ms against 13.8 ms). The A column ran first
in each round and caught a load spike to 17 in round 1; where both single-type columns sit at
0.7–0.85× (interop, history edits), that is the baseline's noise, not a gain.

### 17.8 Bytes

`node lists.mjs size-first` measures the **whole sequence surface**: every public function reached
from one module (`lists/surface/{A,E1}/Surface.beni`, a record of all of them plus `member`,
`sort`, `sortBy`, `==` and `<` at `List Int`), compiled by beni, then esbuild `--minify` with
tree-shaking and brotli 11. For A that is core's `List` and §15's `Array` (its beni half and its
adaptive sibling). For E1 and E1t it is the one `List`, whose surface covers both: Elm's `List`
API plus `get`, `set`, `push`, `pop`, `last`, `slice`, `update` and `initialize`. "Runtime" is the
JavaScript alone: `List.js`, `++` and the adaptive sibling for A, the port for E1 and E1t. The
totals include the few `Basics` functions the code calls.

| surface | min | gzip | **brotli** |
|---|--:|--:|--:|
| A: `List` + `Array`, whole surface | 9 737 | 3 477 | **3 208** |
| A: runtime | 4 310 | 1 677 | **1 575** |
| E1: one `List`, whole surface | 9 041 | 3 328 | **3 090** |
| E1: runtime (`ports/first.js` over `single.js`, `adaptive.js`, `cow.js`, `trie.js`) | 4 957 | 1 920 | **1 803** |
| E1t: one `List`, whole surface | 8 228 | 3 117 | **2 878** |
| E1t: runtime (`ports/first-tail.js`) | 4 137 | 1 703 | **1 602** |

**One array-first type is 10 % smaller than today's two** (2 878 against 3 208 bytes): one API
instead of two, and no `fromList`/`toList` between them. E1t's runtime is the same size as A's
(1 602 against 1 575), because it is one self-contained file where E1 layers four ports.

### 17.9 Verdict

Ratios to A at n = 1 000 / 10 000 / 100 000, E1t in the first pass (alone in brackets where the
two disagree).

| scenario | shape | E1 ÷ A | E1t ÷ A | catastrophic for E1t? |
|---|---|--:|--:|---|
| 1 | `map`/`filter` by hand | 4.8–11, A overflows at 100 000 | 1.9–3.7 (2.5–3.4) | no; ≤ 3.7×, constant, and A overflows |
| 1, 4 | accumulator built by `push`: in a fold, a record field, a tuple; `takeWhile`, `pairwise`, order-keeping fold | 2.8–10 (0.9 for `map` at 100 000) | 0.8–2.9 | no |
| 2 | `sum` by `x :: rest` | 3.7–7.7 | 3.8–7.7 | **yes by the 3× rule**: a view per step; `List.foldl` is the array-first walk, and rule R3 would remove the view |
| 2 | merge sort | 3.2–6.7 | 2.0–3.9 | borderline at 1 000 (3.0 alone); completes at 100 000 where A overflows |
| 3 | library: `foldr`, `range`, `map2`, `concatMap`, `++`, `reverse`, `map`, `filter` | 0.07–2.0; 2.8–5.3 for `range`, `reverse` at 100 000 | 0.06–1.7; 2.8–5.3 for `range`, `reverse` at 100 000 (2.1–2.3 alone) | no; the 100 000 cells are A's process state |
| 3 | `acc ++ [ x ]` → `push` | 0.00–0.02 | 0.00 | no; A is the quadratic one (107 s at 100 000) |
| 4 | kept paths sharing a prefix | 13–41 | 4.5 / 5.4 / 17 (4.8 / 4.1 / 5.4) | **yes by the 3× rule**: a header per version, 1.1–1.4× A's retained memory, nothing quadratic |
| 4 | undo stack | 5.3–11 | 3.5–4.2 (3.2–3.9) | **yes by the 3× rule**: a `Just` and a header per step and a tail copy per undo |
| 5 | TEA list: add, remove, toggle, render | 0.6–1.8 | 0.5–1.7 | no |
| 6 | §15's arrays: reads, walks, writes, interop | 0.68–1.75 (§16.5: 0.92–1.38) | 0.23–1.29 | no |

**Stack**: A overflows in 6 of 30 ops at 100 000 on Node's default stack; E1 and E1t in none.
**Memory**: no blow-up anywhere; E1t retains 0.2–0.65× A except the kept paths (1.1–1.4×), and
peaks at most 1.9× A at 100 000 except the undo stack (4.5×). **Bytes**: E1t's whole surface is
2 878 bytes brotli against A's 3 208.

**Can beni have one sequence type, array-first, with nothing catastrophically worse than A?**

* **With E1, no.** Array-first code is no longer quadratic under it, but §15's persistent `push`
  (a copy per push below 256 elements, a 16-element tail copy per push above) makes every build
  3–11× A and kept paths 13–41×, with 44 MB retained where A keeps 9 MB. Changing the code is not
  enough; the representation has to be built for `push`.
* **With E1t, almost.** It has **no quadratic case, no stack overflow, no memory blow-up**, it
  ties or beats A on every library, accumulator, TEA and array row, and it is 10 % smaller. Three
  shapes stay over the 3× line, each a constant factor that does not grow with n: a bare
  `x :: rest` walk (3.8–7.9×, a view allocated per step), a persistent undo stack (3.2–4.2×) and
  many kept versions sharing a prefix (4–5×, 17× in one run at 100 000). In absolute terms, at
  1 000 elements they cost 13 µs against 3.5 µs, 41 µs against 11 µs and 52 µs against 12 µs; at
  100 000, 0.85 ms against 0.15 ms, 6.1 ms against 1.5 ms and 14–27 ms against 1.6–2.7 ms. The
  first is closable by the compiler with §16.3's local rule R3 (scalar views), since the view
  never escapes the loop. The other two are what persistence costs on an array: every version of
  a stack or a path is a trie header of five fields where a cons version is one cell, and no local
  rule makes a shared, retained version cheaper. A cons list is the better structure for exactly
  those two jobs, persistent stacks and prefix-sharing paths, and nothing else in this study.

If the owner takes one type, it should be **E1t's representation** (adaptive with a claimable
tail and a push threshold of 32, T = 256 for `set`/`pop`), **the builder-based core** of §17.1,
R3 in the lowering, and a lowering that binds a pattern's tail only on the branch that uses it
(§17.2's fix). What remains is a 3–5× constant on persistent stacks and prefix-sharing paths,
paid in exchange for no stack overflows, a third of the retained memory on everything else, and
one API instead of two.

### 17.10 Reproducing

From `bench/arrays/`, after `zig build` at the root and `npm ci`:

```sh
node lists.mjs build && CANDS=A,Ac,B,C,E1,E1t,E1t256 node lists.mjs test && node lists/claim-test.mjs
node scenarios.mjs build && CANDS=cow,adaptive256,single256,firsttail node scenarios.mjs test
for r in 1 2 3 4 5; do RESULTS=results/first.jsonl SIZES=1000,10000,100000 \
  SKIP_AT='append in a loop, acc ++ [x]@100000' SKIP_AT_IMPL=A node lists.mjs bench 5 A E1 E1t E1t256; done
for r in 1 2 3; do WARM_MS=300 RESULTS=results/first.jsonl node lists.mjs alone 5 A E1 E1t; done
CANDS=A,E1,E1t node lists.mjs stack
CANDS=A,E1,E1t MEMOPS=all MEMRESULTS=results/first-mem.jsonl node lists.mjs mem 5
for r in 1 2 3; do RESULTS=results/first-scenarios.jsonl node scenarios.mjs bench 5 adaptive256 single256 firsttail; done
node lists.mjs size-first
node lists.mjs tables-first results/first.jsonl A,E1,E1t,E1t256 results/first-mem.jsonl
ALONE=1 node lists.mjs tables-first results/first.jsonl A,E1,E1t
node lists.mjs tables-arrays results/first-scenarios.jsonl single256,firsttail
```

The files:

* the array-first programs, `lists/first/{Recur,Lib,Paths,Todo}.beni`; §16's, with the two new
  rows (`sumFold`, `undoSession`), in `lists/src/`;
* the array-first core, `lists/first-core/List.{beni,js}`, and the size surfaces,
  `lists/surface/{A,E1}/Surface.beni`;
* E1's sibling `ports/first.js` (over §16's `ports/single.js`), E1t's `ports/first-tail.js`, and
  E1t under §15's Array API, `ports/first-tail-array.js`;
* the persistence test of the claimable tail, `lists/claim-test.mjs`;
* the raw cells: `results/first.jsonl` (both passes; the second is tagged `alone`),
  `results/first-mem.jsonl`, `results/first-stack.jsonl` and `results/first-scenarios.jsonl`.
