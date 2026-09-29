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
numeric or `Bytes` type).

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
