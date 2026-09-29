# The adaptive `Array` sibling under brotli: how small, and how

**Commissioned by** the owner's follow-up to research 38 §15.10: the adaptive `core/Array`
sibling (`bench/arrays/ports/adaptive.js` with the cow and trie code it reaches) measured
**1 499 bytes** brotli-11 through `esbuild --minify`. How small can that payload get by hand, which
techniques buy the bytes, which of them beni's release compactor (`src/js/Minify.zig`) could do by
itself, and how should beni's hand-written JavaScript be written so that it compresses well?

**What this is.** Measurements, on `master` at `106381ca`, Node 24.19, of one file — the whole
`_core/Array.foreign.mjs` surface of research 38 §15: the ten `foreign` exports of
`bench/arrays/scenarios/Array.beni` (`length`, `unsafeGet`, `set`, `push`, `pop`, `slice`,
`append`, `fromList`, `toList`, `sortWith`) plus `fromJs`, `toJs` and the leaf walk `chunks` — taken
from as written, through every minifier, to rewritten and then minified by hand, with each step's
brotli bytes attributed. Every variant passes the scenario harness's 298 checks and a new random
differential test against the original, and the smallest one was timed on all of §15's scenarios.
**What this is not.** A change to `src/`: the compactor transformations of §7 are proposals with
their soundness conditions, priced here by prototypes.

**Read §0, then §7 and §8.**

---

## 0. Findings

### 0.1 The answer

**1 093 bytes** brotli-11 for the whole 13-export surface, by hand (`bench/arrays/min/array.min.js`),
against 1 499 through esbuild in research 38 and **1 624 through beni's `--release` today**. It is
27 % below the esbuild figure and 22 % below terser at its strongest sound settings (1 403). It has
the same behaviour result for result: the same values, the same representation (a plain array, or
the trie node for node), the same identities, and §7's no-ops still return their input. And it has
the same speed: the median cell of §15's 73 is 0.999× the original's. Of the cells that moved by more
than their noise in the five-round run, one runs no code that differs between the two files and
the others were within 1 % in a focused re-run (§6).

In a real `beni build --release` of the seven scenario modules, the compactor cuts the file to the
eight exports they import: **901 bytes**. A program that only reads (the `Decoded` scenario) gets
**452 bytes**, because the file is written so that the compactor can drop the trie's whole write
half (§5).

| | raw | gzip-9 | **brotli-11** |
|---|--:|--:|--:|
| `original.js` as written (the ports, merged, comments kept) | 9 148 | 3 248 | **2 859** |
| … beni `--release` today | 4 921 | 1 699 | **1 624** |
| … esbuild `--minify` (research 38 §15.10's method; the report measured 1 499) | 3 978 | 1 549 | **1 478** |
| … terser, passes 3, toplevel, unsafe_arrows, pure_getters | 3 920 | 1 476 | **1 403** |
| `rewritten.js` (readable, the §8 rules) through beni `--release` today | 3 234 | 1 295 | **1 257** |
| … plus two lexical passes beni could add (§7: A2, A3) | 2 752 | 1 201 | **1 144** |
| … through terser | 2 714 | 1 194 | **1 133** |
| **`array.min.js`, by hand** | 2 548 | 1 169 | **1 093** |
| `array.min.js` cut by a real `--release` build of the seven scenarios | 1 985 | 950 | **901** |
| … of `Decoded` alone, which never writes | 796 | 465 | **452** |

(1 478 is esbuild over the merged `original.js`; research 38's 1 499 bundled `common()`'s second
copy of the leaf walk, which the merge removes. The difference is the first technique of §4.)

### 0.2 What bought the bytes

Measured after terser, so that each technique's bytes are what is left once a good minifier has
done its part (§4 has the ledger, after beni's compactor too):

1. **One path-copy function for every write into a node** (−113): `set`'s path copy, the
   push-a-leaf path copy, the new-path builder and the tail update are the same walk with a
   different stopping depth, and a missing child starts as `[]`.
2. **Walks built on one leaf walk** (−45): `toList` and `toArray` run over `chunks`, which the
   renderer needed anyway, instead of four recursive folds.
3. **Compact paths** (−46): one leaf descent shared by `get` and `pop`, `popLeaf` as one
   expression, no `trieConcat`, the slice identity by arithmetic instead of normalised indices.
4. **One dispatch per write** (−33): the no-op check hoisted before the representation switch, and
   the cow/trie pairs of `set`/`push`/`pop` merged into the exports.
5. **Writing the minified file by hand** (−17 after terser, −141 after beni's compactor), and
   **ordering the top-level statements by search** (−23): brotli rewards putting look-alike
   statements where its matcher finds them, and nobody can predict where that is (§4.3).
6. **Splitting readers from the write half** (−34, and −213 more for a read-only program): readers
   name no write code, so the compactor's statement-level elimination can drop it (§5).

**Brotli made several classic minifier tricks worthless**: a two-byte saving inside a phrase that
repeats is a zero-byte saving after compression. Whether the top-level names are `A…Z` in any
permutation moved the size by **0** bytes; `===` versus `==` by 9–12; `const` versus `let` by 8–20;
a node constructor helper by −13 to +17 depending on its surroundings (§4.2).

### 0.3 For beni's compactor

**Two lexical passes, no parser and no scope analysis, take the readable `rewritten.js` from 1 257
to 1 144 — within 11 bytes of terser (1 133).** A2 renames every identifier that the file binds
and never uses as a property name, everywhere at once, to a fresh short name; because the renaming
is injective onto names the file never uses, it cannot change what any use refers to, so it needs
tokens and not scopes. A3 is three token rewrites (`const`→`let`, `(x)=>`→`x=>`, `;}`→`}`). Both
are prototyped in `bench/arrays/min/rename.mjs` and `measure.mjs`, and their output passes the
differential tests. §7 has the list, ordered by bytes per unit of work.

### 0.4 For whoever writes `core/` and platform JavaScript

§8 has the rules. The three that matter most: **write the same walk once** (every duplicate
walk is worth more than any renaming), **keep readers from naming write code** (the compactor keeps
every top-level statement a live statement names, so one careless mention keeps the trie), and
**reuse parameter names consistently** (`a` is always the array, `i` the index, `x` a node): a
duplicated 79-byte statement costs 13 bytes if its locals match and 39 if they are renamed (§1.5).

### 0.5 Found on the way

* **`boundary.md` §4's check 3 refuses a `function f(a, extra)` declaration** whose parameter name
  is not bound anywhere else in the file: `src/js/Sibling.zig`'s scan checks `isDeclarator` before
  its `function name(params)` branch, so that branch is unreachable and the parameters are read as
  references. `original.js` (the ports' own `function copy(a, extra)`) is refused as
  `UNBOUND JAVASCRIPT REFERENCE … uses 'extra'`. Nothing in `core/` or `platforms/` declares a
  function that way, so no shipped file is affected. It wants a `tests/corpus/` fixture and a
  one-line reorder; this task did not change `src/`.
* **Research 38 §12.2's "a loop below 64 elements (V8's slice/concat have a high fixed cost)"** does
  not hold on Node 24's V8: `slice()` is equal at 8 elements and 1.5× faster at 32–63; the loop wins
  only at 2 (§6.3). The loop may still be right on SpiderMonkey or JSC, which this report did not
  measure; replacing it saves 23 bytes and is listed as flagged, not taken.
* The adaptive port exports `fromList` and `toJs` as bare names, which §4 check 4 refuses;
  `original.js` writes their parameter lists out.

---

## 1. How brotli prices a small JavaScript file

Brotli (RFC 7932) is LZ77 followed by entropy coding, with context modelling and a built-in
dictionary. What follows is what a writer of a 1–3 KB file needs from it; the section numbers are
the RFC's.

### 1.1 Commands: literals, copies and distances

A compressed stream is a sequence of meta-blocks (§9.2), and a meta-block's data is a sequence of
**commands** (§2, §9.3). Each command is *insert n literal bytes, then copy m bytes from d bytes
back*. The insert length and the copy length are coded together as one **insert-and-copy length
symbol** from a 704-symbol alphabet, plus extra bits (§5); the shortest copy is **2 bytes**. The
literals are coded one symbol each, and the distance is coded as a distance symbol plus extra bits
(§4).

**Distances are cheap when they repeat** (§4). The decoder keeps a ring buffer of the last four
distances. Distance codes 0–3 mean "the last, second-, third- or fourth-last distance", and 4–15
mean "the last or second-last distance, plus or minus 1 to 3", with no extra bits. Better still, an
insert-and-copy symbol in the range 0–127 **implies distance code 0**, the last distance, with no
distance symbol at all (§5). So when a file repeats a *pattern* — two parallel functions whose
matching parts sit at the same offset from each other — every copy after the first costs little
more than its command symbol. A new distance costs its symbol plus roughly log2(d) − 1 extra bits,
so a copy from 200 bytes back costs a few bits more than one from 20, and a copy from 2 000 back a
few more again.

### 1.2 Prefix codes and context modelling

Every alphabet is coded with canonical prefix (Huffman) codes, sent in the meta-block header (§3).
Literals are coded with **context modelling** (§7): each literal's prefix code is chosen by a
context computed from the two bytes before it (four context modes: LSB6, MSB6, UTF8, signed), and a
context map sends the 64 contexts per block type to a smaller set of prefix codes. Distances are
coded in one of four contexts by copy length. Block switch commands (§6) let one meta-block change
prefix codes midway. The practical consequence: **a literal is cheap when it is predictable from
the two bytes before it**. `a.` followed by `n`, `s`, `r` or `t` costs a fraction of a byte;
an unusual letter in an unusual place costs a whole byte or more.

### 1.3 The static dictionary

Brotli carries a **122 784-byte dictionary of 13 504 words** of 4 to 24 bytes, English and web text
(§8, Appendix A), usable through **121 transforms** (Appendix B: prefixes and suffixes such as
`" "`, `"."`, `"("`, and uppercasing). A copy whose distance exceeds the window and everything
decoded so far refers to a dictionary word instead; the word's index and the transform are coded in
the excess (§8).

Which JavaScript is in it (checked by dumping the dictionary with `BrotliGetDictionary()`): **in**:
`function`, `return`, `length`, `.length`, `slice`, `push`, `null`, `true`, `false`, `while`,
`else`, `this`, `this.`, `sort`, `apply`, `filter`, `prototype`, `undefined`, `document`, `window`,
`object`, `array`, `value`, `import`, `default`, `static`, `class`, `var `, `return `.
**Not in**: `const`, `let`, `export`, `concat`, `Array`, `isArray`, `Math` (only `Math.floor(` and
`Math.random()`), `=>`, `===`, and no beni name at all (`unsafeGet`, `sortWith`, `fromList`, …).

**At this size the dictionary is worth a few bytes and nothing to write for.** A dictionary hit
saves only the word's *first* occurrence, since later ones are ordinary back-references. The probe
(`bench/arrays/min/brotli-probes.mjs`) replaces every occurrence of a word by a same-length
non-word: dictionary words cost +6 to +14 bytes, and control words that are not in the dictionary
cost +7 to +11. The two cannot be told apart, because the substitution's disturbance of the literal
statistics is as large as the dictionary's saving.

### 1.4 Quality 11 and the window

The format fixes what can be said, and the encoder chooses what to say. Quality 10 and 11 of the
reference encoder parse **optimally**, Zopfli-style: they find every match at each position with a
binary-tree hasher, and they choose the cheapest path through all of them under the prefix codes
being built. Quality 11 iterates that choice, and it also searches the last 64 bytes for 2- and
3-byte matches, where every other quality searches 16 (`c/enc/hash_to_binary_tree_inc.h`,
`short_match_max_backward`; the tree itself starts at 4-byte matches). Measured on
`array.min.js`: quality 5 gives 1 140 bytes, 9 gives 1 133, 10 gives 1 111 and 11 gives 1 093. The
window (WBITS, §9.1: 2^WBITS − 16 bytes, 10 to 24) does not matter once it covers the file: lgwin 16
and 22 both give 1 093. lgwin 10 gives 1 164, because a 1 KB window cannot see the whole 2.5 KB
file. The text-mode hint changes nothing.

### 1.5 What this predicts, and the probes that check it

* **Repeating an exact byte string is nearly free, and the price is in what differs.** Appending
  a 79-byte statement's twin, renamed at its top-level name only, costs **+13 bytes** at the end of
  the file and +20 next to itself. The same twin with its four locals renamed costs **+39**.
  *Consistent parameter names across functions are worth more than short ones.*
* **Unique short names buy nothing and cost nothing.** Every name that occurs once or a few times
  is a literal whichever letter it is: a hill-climb over all bijections of the 19 top-level letters
  onto `A–Z` (`min/tools/order.mjs names`, 2 000 trials) found **0** bytes. Doubling each name
  to two letters costs +52 (74 raw).
* **Raw bytes inside repeated phrases are nearly free, and raw bytes do not predict brotli
  bytes.** `export const` for `export let` is 26 raw bytes and 7–12 brotli; a newline per statement
  is 83 raw and 21–31 brotli; `===` for `==` is 6 raw and 9–12 brotli, because it disturbs more than
  it adds (§4.2).
* **Order matters, and cannot be predicted.** Brotli prices each copy by its distance and by what
  the distance cache holds, so moving statements next to their look-alikes changes the bill. A
  hill-climb over the order of the 32 top-level statements (3 000 swaps and moves) found **−21**
  bytes. The winning order is not one a person would guess (§4.3).
* **Structure is what pays.** Every technique in §0.2 that bought more than 30 bytes removed a
  *distinct* piece of code. None of them shortened a repeated one.

---

## 2. Method

**The file.** `bench/arrays/min/original.js` is the adaptive sibling as it would be written as
`core/Array.js`. It is `ports/adaptive.js`, the parts of `ports/cow.js` and `ports/trie.js` it
reaches, and `scenarios.mjs`'s `common()` surface, merged into one file. The code is the ports'
statement for statement: names prefixed where the merge would clash (`cowSet`, `trieSet`), the leaf
walk written once instead of twice, `fromList` and `toJs` given parameter lists (§0.5), and the
threshold T fixed at 1 024 as in adaptive1024. §15.11's suggested T = 256 changes one number and no
byte count.

**The measurements.** Brotli quality 11, lgwin 22; gzip level 9; Node's zlib. **beni `--release`
today** is `src/js/Minify.zig` itself, compiled into a filter (`bench/arrays/min/minify.zig`, linked
against `src/beni.zig`) that takes a file and the exports to keep. The real compiler is also run:
`measure.mjs release` builds the scenario modules with `beni build --release` against a copy of
`core/` whose `Array` is `min/Array.beni`. That is `scenarios/Array.beni` with `fromJs`, `toJs` and
`chunks` declared too, so that check 2 accepts a sibling exporting all 13. terser 5 at
`compress: {passes: 3, toplevel, unsafe_arrows, pure_getters}, mangle: {toplevel}` is the strongest
setting that is sound here. `mangle.properties` is not: `$`, `a` and `b` are the beni list cells'
fields, and `n`, `s`, `r`, `t` are already one letter.

**Correctness, three ways.** Every variant:

1. passes `scenarios.mjs`'s differential test, the same 298 checks line for line as cow
   (`measure.mjs test`). That includes §7's identity checks: `swap i i` and an out-of-range update
   return `model.rows` itself.
2. passes a new **random differential test** against `original.js` (`measure.mjs fuzz`): 12
   operations on random versions of random sizes, each result compared by `JSON.stringify` (which
   spells out the representation, plain array or `{n, s, r, t}` trie node for node), by identity
   with its input, and by its `toJs`, `chunks`, `toList` and first and last `unsafeGet`. It runs
   once as written and once with the threshold rewritten to 4, so that small arrays reach the
   tail, root splits at 1 056 and 33 824 elements, and root collapses. That is 16 000 + 2 400
   results per sibling. It was checked by mutation: ten one-token mutants of `rewritten.js`
   (a boundary `>` for `>=`, a dropped identity case, a wrong split shift, …) are all caught.
   A first version with an LCG's low bits for `% n` caught only three of them.
3. for the three final files, `beni build --release` accepts them (checks 1–4) and its compactor
   does not decline them.

**Speed.** `measure.mjs bench`: §15's harness and cells unchanged, one `node --expose-gc` process
per sibling, pinned to one otherwise idle core (`taskset -c 10`; core 13 was busy with another
job), siblings interleaved over **five rounds**, each cell the median of its five round medians. A
cell's noise is the spread of the original's five round medians, (max − min) / median.

---

## 3. The stages

The whole surface, 13 exports (`node min/measure.mjs size`):

| stage | raw | gzip-9 | brotli-11 | Δ brotli |
|---|--:|--:|--:|--:|
| 0 `original.js`, as written | 9 148 | 3 248 | **2 859** | |
| 0a beni `--release` today (`Minify.zig`: comments and whitespace) | 4 921 | 1 699 | **1 624** | −1 235 |
| 0b + A2, renaming by tokens (`rename.mjs`) | 4 337 | 1 612 | **1 515** | −109 |
| 0c + A3, `const`→`let`, `(x)=>`→`x=>`, `;}`→`}` | 4 193 | 1 591 | **1 503** | −12 |
| 0d beni today + terser mangle, locals only (scope analysis) | 4 716 | 1 603 | **1 522** | |
| 0e beni today + terser mangle, every name | 4 163 | 1 529 | **1 431** | |
| 0f esbuild `--minify` | 3 978 | 1 549 | **1 478** | |
| 0g terser defaults | 3 984 | 1 487 | **1 421** | |
| 0h terser, best sound settings | 3 920 | 1 476 | **1 403** | |
| 1 `rewritten.js`, as written | 7 214 | 2 823 | **2 482** | |
| 1a beni `--release` today | 3 234 | 1 295 | **1 257** | −1 225 |
| 1b + A2 | 2 905 | 1 218 | **1 170** | −87 |
| 1c + A3 | 2 752 | 1 201 | **1 144** | −26 |
| 1d beni today + terser mangle, locals only | 3 121 | 1 254 | **1 196** | |
| 1e beni today + terser mangle, every name | 2 846 | 1 196 | **1 140** | |
| 1f esbuild `--minify` | 2 629 | 1 213 | **1 172** | |
| 1g / 1h terser, defaults and best | 2 714 | 1 194 | **1 133** | |
| 2 **`array.min.js`, by hand** | 2 548 | 1 169 | **1 093** | |
| 2a `array.min.js` through beni `--release` today | 2 549 | 1 172 | **1 097** | |
| 2h `array.min.js` through terser best | 2 451 | 1 143 | **1 093** | |

Five things to read from it:

* **beni's compactor does most of the work**: dropping comments and whitespace takes 43 % off
  the brotli bytes of the file as written.
* **What terser adds over the compactor is almost all renaming**. On `original.js`, renaming every
  name (0e) is 1 431 and all of terser (0h) is 1 403. Terser's `compress` buys 28 bytes on the
  original and 7 on the rewrite.
* **Locals-only renaming (0d, 1d) buys half of it.** Top-level names are the long ones (`trieFromArray`,
  `ToArray`), and with them renamed too the file gains 91 more bytes on the original and 56 on the
  rewrite. A2 renames both without a scope analysis.
* **Rewriting the source is worth more than any minifier**: `rewritten.js` through the compactor as
  it is today (1 257) beats `original.js` through terser (1 403).
* **Hand minification over the rewrite buys 40 bytes over terser**: 17 from writing the minified
  text by hand (§4.2) and 23 from statement order (§4.3). terser run over the hand file finds
  nothing (1 093).

---

## 4. The ledger: which technique bought what

### 4.1 Readable steps

`bench/arrays/min/steps/00…07` are readable sources, each the one before it with one technique
applied. Every one passes both differential tests. The columns are after beni's compactor as it is
today and after terser best:

| step | technique | beni | Δ | terser | Δ |
|---|---|--:|--:|--:|--:|
| 00 | `original.js` | 1 624 | | 1 403 | |
| 01 | `toList` and `toArray` over `chunks`: drop `cowToCons`, `trieToCons`, `trieFoldr`, `foldrNode` | 1 543 | −81 | 1 358 | −45 |
| 02 | one dispatch per write: no-op check hoisted, cow and trie `set`/`push`/`pop` merged into the exports | 1 493 | −50 | 1 325 | −33 |
| 03 | a node constructor `node(n, s, r, t)` for every trie object | 1 497 | +4 | 1 342 | +17 |
| 04 | `fromArray` by one `group` loop, with no `tailOff` and no `n == 0` or `o == 0` cases | 1 468 | −29 | 1 326 | −16 |
| 05 | one path copy (`setIn` with a stopping depth; a missing child is `[]`): drop `path`, `pushLeaf`, `addLeaf`'s tuple; `grow(a, t)` with the root wrapped as `[r]`; append element by element through `grow` | 1 378 | −90 | 1 213 | −113 |
| 06 | one `leaf(a, i)` descent for `get` and `pop`; `popLeaf` as one expression; no `trieConcat`; slice identity by arithmetic; cow helpers inlined | 1 295 | −83 | 1 167 | −46 |
| 07 | readers split from the write half (§5), capitalised top-level names, arrow constants = `rewritten.js` | 1 257 | −38 | 1 133 | −34 |

The steps are behaviour-preserving by the tests, and speed-neutral by §6 for the endpoint (07).
Two of them changed code on the write path and were timed on their own:

* **05's element-by-element append** replaces a loop that copies up to 32 elements at a time.
  None of §15's cells appends onto a trie (their `append` rows append onto a plain array), so it
  has its own benchmark, `min/append-bench.mjs`, median of 7, two processes each:

  | append onto a trie | `original.js` | `array.min.js` | `rewritten.js` |
  |---|--:|--:|--:|
  | 10 000 + 1 000 | 7.51 / 7.73 µs | 7.23 / 7.22 µs | 6.71 µs |
  | 10 000 + 10 | 0.21 / 0.29 µs | 0.09 / 0.09 µs | 0.08 µs |
  | 100 000 + 1 000 | 6.78 / 6.87 µs | 7.04 / 7.03 µs | 6.80 µs |
  | 100 000 + 100 000 | 1 099 / 1 147 µs | 781 / 757 µs | 755 µs |

  Equal, or faster: the original also rebuilt `b` into a trie and flattened it back when `b` was
  plain.
* **06's slice identity arithmetic.** The whole-range test `(s < 0 ? s + n : s) <= 0 &&
  (e < 0 ? Math.max(0, e + n) : e) >= n` is exact, including the empty trie. The tempting
  `r = toJs(a).slice(s, e); return r.length === n ? a : r` would flatten a whole trie to return
  it unchanged, and it differs on empty plain arrays; it was not taken.

### 4.2 From the rewrite to the hand file

`steps/10-hand.js` is `rewritten.js` minified by hand: 1 116 bytes, 17 under terser over the same
source. It keeps two structural changes that terser cannot make. `SetIn` and `PushLeaf` are
merged, which was −26 on the first hand draft and is step 05 in the readable ledger, and `set`
writes the tail through the same path copy. Everything else is spelling. The spellings were chosen
by pricing each alternative alone (`min/tools/trials.mjs`); the table is that tool's output. Every
row is the price of switching **away** from what the file does:

| edit, alone | Δ raw | Δ brotli on `10-hand.js` (1 116) | Δ brotli on `array.min.js` (1 093) |
|---|--:|--:|--:|
| `const` everywhere instead of `let` | +94 | +8 | +20 |
| `export const` instead of `export let` | +26 | +12 | +7 |
| threshold as `L=1024` instead of `1024` three times | +2 | +6 | +13 |
| `===` everywhere instead of `==` where both sides are known numbers or strings | +6 | +12 | +9 |
| `new Array(` instead of `Array(` | +4 | +8 | +10 |
| object literals instead of the node constructor `M(n, s, r, t)` | +13 | +4 | +13 |
| one joined `let a=…,b=…` for the internal statements (breaks elimination, §5) | −80 | −2 | +15 |
| a newline after every `;` | +83 | +21 | +31 |
| `set` writes the tail with a slice instead of the path copy | +10 | +6 | +5 |
| `push` writes the tail with the path copy instead of slice and push | −11 | +4 | +3 |
| comparator `(x=f(x,y))=="GT"\|-(x=="LT")` instead of the ternary chain | −4 | +5 | +5 |
| `!r[1]` instead of `r.length==1` | −6 | +5 | +8 |
| `G` without its default parameter used as a local | +2 | +2 | +9 |
| `G` without the bounds check that `unsafeGet`'s contract makes dead | −33 | 0 | +2 |
| `sortWith` copies through `[...P(a)]` | −12 | +6 | +9 |

Three things show in it:

* **Raw bytes do not predict brotli bytes.** Four edits that *save* raw bytes cost brotli bytes,
  and 94 raw bytes of `const` cost 8.
* **The two columns disagree by up to 17 bytes on the same edit.** Every size in this report
  moves by ±5 for any edit, and a statement order found by search sits in a local minimum that any
  edit disturbs (§4.3). Only the signs and the larger magnitudes carry information.
* **The node constructor, taken as a technique, is noise.** It was +17 in the readable ledger
  (step 03, after terser) and it is −4 to −13 here.

### 4.3 Statement order

`steps/11-order.js` is `10-hand.js` with its 32 top-level statements put in the order a hill-climb
found (`min/tools/order.mjs order`: 3 000 random swaps and moves, keeping any that shrink the
brotli output; deterministic, and it reproduces the file byte for byte): **−23 bytes**, to 1 093,
of which 2 are the trailing newline the tool drops and 21 are the order. That is `array.min.js`. Any order is correct here, because no initialiser reads another
binding at load time: `Array.isArray` is the only non-literal. The found order interleaves readers
and writers in a way no rule predicts (`toList` right after `Array.isArray`, `pop` among the reader
helpers). What it exploits is brotli's distance cache and its matcher, not the meaning of the code.

This is a compressor-in-the-loop search, and it overfits. It is a one-time layout choice for a file
that ships in the box, not a compiler pass: 3 000 brotli-11 runs of a 2.5 KB file take about 10 s.

### 4.4 Flagged: smaller, but not taken

| file | change | brotli | Δ | speed (§6) |
|---|---|--:|--:|---|
| `flagged/build-by-append.js` | build the trie by appending to `Empty`: drop `Group` and `Build`'s level loop | 1 057 | −36 | **first write 4–16× slower**, 16 % more retained memory |
| `flagged/cow-copy-by-slice.js` | plain-array copies by `slice()` and `concat()` only: drop the loop below 64 | 1 070 | −23 | neutral on V8 (§6.3), unmeasured elsewhere |
| `flagged/both.js` | both | 1 023 | −70 | as the first |
| (not kept) | drop the trie `get`'s bounds check, which `unsafeGet`'s contract makes dead | 1 095 | +2 | — |
| (not kept) | `sortWith` copies through `[...toJs(a)]` | 1 102 | +9 | an extra copy for a trie |

**Build-by-append is rejected.** The conversion is what adaptive's first write pays (§15.8), and
building the trie with an array `push` per element makes it 11–16× slower. It also leaves every leaf
with a grown backing store, which is where the 16 % more memory for 101 versions comes from, even
though the trie is node for node the same. **Cow-copy-by-slice is a candidate for the owner** once
it is measured on SpiderMonkey and JSC (§6.3).

---

## 5. The tree-shaking split

beni's compactor cuts a sibling to the exports the build imports: a top-level statement survives
iff it is a root or a surviving statement **mentions** a name it declares. A mention is any
identifier token not after `.` or `?.`, with no scope analysis (backend.md §9, *Hand-written
JavaScript under `--release`*). A program that never calls `set`, `push` or `pop` can never hold a
trie, because every trie is born of a write to a long plain array. The trie's write code is then
dead, but only a type-state analysis could know that. What the file can do is make that code
**unmentioned** by the readers.

`rewritten.js` does it with three rules:

1. **Readers never name write code.** `append`, a reader, must append onto a trie when it is given
   one, which needs the write machinery. It calls it through `let Grower;`, which the one place a
   trie is born (`Build`) sets to `AppendTrie`. A trie exists only after `Build` has run, so the
   binding is always set when it is read. The compactor keeps `let Grower;`, an inert declaration,
   and nothing it would have pulled in.
2. **Reading a trie stays reader code.** The first version sent `unsafeGet`'s trie branch through
   the same kind of binding (`W.get`), and it cost **15–18 %** on the history scenario's undo fold,
   a `foldl` over a trie through `unsafeGet`, and on `remove one` at 1 000 rows. The indirection
   also hurt a read site that never saw a trie, presumably through the inliner. Measured on a
   variant with a direct `Get` and otherwise identical: 1.01×. So `Get` and its `Leaf` descent are
   mentioned directly, and a read-only program keeps them (about 150 raw bytes).
3. **Top-level names are capitalised and locals are not.** A local named like a top-level
   statement would keep that statement alive by mention. In the hand file, top-level names are
   single capitals and locals are lower case.

Kept exports as the compactor cuts them (`measure.mjs size`, the `Minify.zig` filter):

| sibling | exports kept | raw | gzip-9 | brotli-11 | Δ vs all 13 |
|---|---|--:|--:|--:|--:|
| `original.js` | all 13 | 4 921 | 1 699 | **1 624** | |
| `original.js` | the 10 readers | 3 140 | 1 246 | **1 186** | −438 |
| step 06 (before the split) | the 10 readers | 2 051 | | **873** | |
| `rewritten.js` | all 13 | 3 234 | 1 295 | **1 257** | |
| `rewritten.js` | the 10 readers | 1 476 | 675 | **660** | −597 |
| `array.min.js` | all 13 | 2 549 | 1 172 | **1 097** | |
| `array.min.js` | the 10 readers | 1 138 | 608 | **584** | −513 |
| `array.min.js` | `length`, `unsafeGet`, `fromList` | 331 | 233 | **212** | −885 |

The split buys 213 bytes for a read-only program (873 → 660) at a cost of nothing for the whole
surface: step 07 is 38 bytes *smaller* than 06. `original.js` keeps 1 186 because its `append`
names `trieFromArray`, which drags in the whole build.

The real compiler, `beni build --release` of the scenario modules (`measure.mjs release`):

| sibling | program | `foreign` exports kept | raw | gzip-9 | brotli-11 |
|---|---|---|--:|--:|--:|
| `original.js` | any | refused by check 3 (§0.5) | | | |
| `rewritten.js` | `Decoded` (reads only) | `length`, `unsafeGet`, `slice`, `fromList`, `sortWith` | 1 013 | 511 | **484** |
| `rewritten.js` | all seven scenarios | + `append`, `set`, `push` | 2 549 | 1 063 | **1 027** |
| `array.min.js` | `Decoded` (reads only) | `length`, `unsafeGet`, `slice`, `fromList`, `sortWith` | 796 | 465 | **452** |
| `array.min.js` | all seven scenarios | + `append`, `set`, `push` | 1 985 | 950 | **901** |

**What a smarter compiler could add.** Even the read-only file keeps `Get`, `Leaf`, `Leaves`,
`Chunks` and `ToArray`, the trie's *read* half, since the readers must accept a trie in general. A
build that imports no writer at all can never see one, so it could link a plain-only sibling:
the cow port's readers, a part of its 536 bytes. That is a sibling-selection mechanism in the
compiler, not something `Minify.zig` can do, and it is noted here unmeasured.

---

## 6. Speed

### 6.1 The smallest correct file against the original

All 73 cells of §15's six scenarios, five interleaved rounds (`min/results.jsonl`, `measure.mjs
tables`). Against `original.js`, cell by cell:

| sibling | median ratio | 10th–90th percentile | cells within ±5 % | within ±10 % |
|---|--:|--:|--:|--:|
| **`array.min.js`** | **0.999** | 0.95–1.05 | 59 of 73 | 67 of 73 |
| `rewritten.js` | 0.998 | 0.96–1.05 | 61 | 70 |
| `flagged/cow-copy-by-slice.js` | 0.994 | 0.96–1.05 | 61 | 72 |
| `flagged/build-by-append.js` | 1.000 | 0.94–1.78 | 46 | 57 |

The six `array.min.js` cells outside ±10 %:

* `append 1000/first` at 1 000 rows (0.49×) is bimodal: the original swings between 40 and 83 µs
  from round to round, a spread of 56 %.
* `decoded/total` at 10 000 (0.88×) has a 23 % spread.
* `decode` at 100 000 (1.11×) calls no sibling code but `fromJs = a => a`, identical in both.
* That leaves `remove one/first` at 10 000 (1.12×), `remove one + add one` at 1 000 (1.11×)
  and `append 1000/first` at 10 000 (0.76×). A **focused re-run** of the table and history
  scenarios, five interleaved rounds (`min/results-focused.jsonl`), puts those three at **0.99×,
  0.99× and 0.99×** and the history undo fold at 0.99×.

**Nothing moved.** Retained memory is identical (178 KB for 101 versions).

### 6.2 What was measured and rejected on the way

* **A late-bound `get`** (§5 rule 2): +15–18 % on a trie fold. Rejected; `Get` is named directly.
* **Build-by-append** (§4.4): the first write on a 10 000-cell grid goes from 9.7 µs to 132 µs,
  and on a million cells from 2.1 ms to 23 ms. `history/edit/first` is 15.7× slower. Rejected.
* **`toArray` by `flat()`**: `a.r.flat(a.s / 5).concat(a.t)` is the shortest correct flattening,
  and it is **2.4–3.8× slower** than `concat.apply` at 2 000–1 000 000 elements
  (`min/tools/flat-bench.mjs`). `[].concat(...leaves)` is 2–3× *faster*, but it passes one argument
  per leaf, and an engine argument limit (JavaScriptCore's is about 65 536) would throw above about 2 million
  elements. Neither was taken.

### 6.3 The copy loop below 64

Research 38 §12.2 keeps a manual copy loop for plain arrays under 64 elements, because "V8's
slice/concat have a high fixed cost". Node 24.19 (`min/tools/copy-bench.mjs`; ns per copy
plus one write, 2 million reps):

| n | loop | `slice()` | `concat()` |
|--:|--:|--:|--:|
| 2 | 9.3 | 24.5 | 26.0 |
| 8 | 22.2 | 21.8 | 25.8 |
| 32 | 52.0 | 33.6 | 36.8 |
| 63 | 94.8 | 56.2 | 57.6 |

On this V8 the loop wins only below about 8 elements and loses 1.5× at 32–63. In the scenarios,
`cow-copy-by-slice` is neutral (0.994× median). Report 38 measured SpiderMonkey and JSC too, and
the loop may have been chosen for them. The owner should re-measure §3's cow `set` there before
taking the 23 bytes.

---

## 7. (a) Transformations beni's compactor could do

Ordered by brotli bytes saved per unit of implementation work. Bytes are measured on the two
readable files (original / rewritten) through the prototypes. Every condition below is one a
tokenizer can check. Anything it cannot check is a refusal, as `Minify.zig` already works.

| # | transformation | bytes (original / rewritten) | work |
|---|---|--:|---|
| A1 | *(done)* comments, whitespace, unimported exports | −1 235 / −1 225 | shipped |
| A2 | renaming by tokens: injective, file-wide | **−109 / −87** | small |
| A3a | `;}` → `}` (applied first) | −14 / 0 | trivial |
| A3b | `(x) =>` → `x =>` (then) | +10 / −18 (the +10 is noise) | trivial |
| A3c | `const` → `let` (then) | −17 / −15 | trivial |
| A5 | statement order by compressor search | −21 (on the hand file) | small code, slow |
| A6 | scope-aware renaming (terser's mangle of every name) instead of A2 + A3 | −72 / −4 | a parser and a scope analysis |
| A7 | `compress`-class rewrites (inlining, dead branches, `if`→`&&`) | −28 / −7 | a parser and an optimiser |

The A3 rows are applied one after another to the compactor's output, without A2
(`min/tools/a3.mjs`). After A2 the three together are −12 / −26, the 0c and 1c rows of §3.

**A2, renaming without scope analysis.** Collect every identifier token (not after `.`/`?.`).
Rename a name X to a fresh short name Y **everywhere in the file at once** iff:

* the file binds X: after `let`, `const`, `var` or `function`, or in a parameter list;
* X is not exported (exports are the boundary with beni's emitted imports; check 2 reads them);
* X never appears where a *property name* can stand: before `:` (an object key, or a label; a
  ternary `c ? X : y` is refused too, which is conservative), as a shorthand `{X}` / `{…, X}`, as a
  method or class member name, in an `import`/`export` specifier list;
* X is not a standard or host global (`isStandardGlobal`'s list, extended by the host names of
  `boundary.md` §5.1). Otherwise a file that binds `document` in one function and reads the global
  `document` in another would have both renamed;
* the file mentions no `eval` and no `with` (the compactor already refuses `eval`);
* Y occurs nowhere in the file, and the map from names to fresh names is injective.

It is sound without scopes because it is **alpha-renaming of all bindings of X at once**. Every
declaration of X and every use of X move together to one fresh Y, so a use that referred to the
innermost X before still refers to the innermost Y after, and no capture is possible because Y was
unused. What it gives up against terser is *reuse*: terser gives every function's first parameter
the same letter. Brotli prices that difference low when the source already reuses names (§8 rule
6). On `rewritten.js`, A2 + A3 reach 1 144 against terser's 1 140 for renaming every name. Shorthand
object properties (`({ n, s, r, t })`) are the common reason a name is refused: here `a`, `b`, `n`,
`s`, `r`, `t` stay as they are, and they are already one letter. The prototype is
`bench/arrays/min/rename.mjs`: a regular-expression tokenizer, fine for these files, which have
no regular expressions and no identifiers inside strings. `Minify.zig`'s tokenizer is the one to
use. **Order**: after elimination, so that names freed by dropped units can be reused.
**Determinism** (rule 5): frequency order, ties broken by first occurrence.

**A3, three token rewrites.** Each is exact at the token level:

* **`const` → `let`**: sound in any file that never assigns a `const` binding, since a program
  that does throws `TypeError`, and no sibling relies on that throw. A lexical check is enough if
  it is wanted: no `X =`, `X +=`, `X++` for a `const`-declared X. `for (const x of …)` becomes
  `for (let x of …)`, which is also fine.
* **`( ident ) =>` → `ident =>`**: exact when the parenthesised list is a single plain identifier.
* **`;` before `}`**: exact unless the `;` is an empty statement: after the `)` of an `if`,
  `for` or `while` head (the tokenizer already marks those), after `else` or `do`, or after a
  label. There it is kept.

**A5, order search.** Correct only when no top-level initialiser reads another top-level binding at
load time. That is the compactor's own *inert* list: literals, functions, arrows, and objects and
arrays of them, plus a read of `Math.x` or `Array.x` of a global. The result depends on the brotli
version, and it costs seconds per file. It is only worth doing for files that ship in the box, once,
checked in as their source order (§8 rule 10).

**Not recommended.**

* **A6/A7** need a JavaScript parser, which `boundary.md` §4's wall exists to avoid. On a file
  written by §8's rules they buy **7–12 bytes**.
* **Property mangling** is unsound: siblings share field names with the emitter (`$`, `a`, `b`) and
  with the runtime.

### Where the bytes would come from on other files

This report measured one file. The same passes on the platform runtimes (research 39 §5 priced
terser against the compactor at 5 133 against 5 315 bytes for the benchmark app) should buy the
same kind of share. That is about 3–7 % of a hand-written file's brotli bytes from A2 + A3, and
more where the file has long top-level names. It should be measured with `bench/size.mjs` before
building.

---

## 8. (b) Writing rules for beni's hand-written JavaScript

For `core/*.js` siblings and platform runtimes. In order of what they bought here:

1. **Write each walk once.** Before adding a loop, look for the one it resembles and give that one
   a parameter (a stopping depth, a direction). Steps 01, 05 and 06 are 254 of the 367 bytes the
   readable steps saved after the compactor, and 204 of 270 after terser. No renaming comes close.
2. **Keep readers from naming write code** when a program might import only readers. The
   compactor keeps every top-level statement a live statement names, and one mention keeps it all.
   Route the rare reader-to-writer call through a binding the writer sets (§5 rule 1). **Never
   route a hot read through one** (§5 rule 2: 15–18 %).
3. **One top-level statement per unit that might be dropped.** `const a = …, b = …;` is one
   unit, and `export { a as x, b as y };` is one unit whose survival keeps every name in it. Write
   `export const x = (…) =>` per export, which check 4 needs anyway.
4. **Capitalise top-level names and keep locals lower case** (or any rule that keeps the two
   namespaces apart), so that a local never keeps a top-level unit alive by sharing its name.
5. **Declarations the compactor can see are inert.** Initialise top-level bindings with literals,
   arrows, functions, or objects and arrays of them. `const E = node(0, 5, [], [])` is a call, a
   root that is never dropped, and it keeps `node` alive. `{ n: 0, s: 5, r: [], t: [] }` is inert.
6. **Reuse parameter names by role, across functions**: `a` for the array, `i` for an index, `v`
   for a value, `x` for a node, `s` for a shift, `n` for a length, `t` for a tail. Brotli prices a
   repeated phrase at a few bits, and a phrase that differs only in its locals at many (+13 against
   +39 bytes in §1.5).
7. **Do not write for the dictionary, and do not shorten repeated phrases.** Short *unique*
   names, `==` for `===`, and `let` for `const` are worth 0–10 bytes after compression. Choose them
   for clarity. The compactor can do A3 itself.
8. **Prefer arrow constants to `function` declarations** in siblings. They are what check 4 counts
   most directly, and today check 3 also misreads a `function f(a, b)` parameter list (§0.5).
9. **Never add parameters to an export.** A default parameter used as a local is a fine size trick
   for *internal* helpers, but on an export it changes the arity that check 4 counts. `(a, i, v, o)`
   for a 3-ary `set` is `foreign_arity_mismatch`.
10. **For a file that ships in the box and is stable, run the order search once** (§4.3) and commit
    its order, with a comment saying the order is deliberate. It is 2 % and it is free at run time.
11. **Keep every speed-motivated line, and give its reason in a comment**, so that the next
    minification pass knows not to "simplify" it. Here that is the copy loop below 64, the
    8 192-leaf `concat.apply` batching, the direct trie `get`, and the slice-based trie build. Each
    of them has a smaller correct form that is slower (§4.4, §6.2).

---

## 9. Caveats

* **Node 24.19 only**, like research 38 §15. §6.3's copy-loop question needs Chrome, Firefox and
  Safari.
* **One file.** The techniques are general. The byte counts are this file's.
* **Brotli's noise floor is about ±5 bytes** for any small edit. Deltas under 10 bytes in §4.2 are
  direction, not magnitude.
* The random differential test compares against `original.js`, so it proves *equivalence to the
  port*, not correctness of the port. The scenario harness (against cow) covers that, as research
  38 §15.2 did.
* The machine was shared: another job held core 13, and these runs used core 10 with its hyperthread
  sibling idle. Round-to-round spread is in the table the `tables` command prints.

## 10. Reproducing

From `bench/arrays/`, after `zig build` at the root:

```sh
npm ci                                        # esbuild, terser (terser added for this report)
node scenarios.mjs build && node scenarios.mjs test
node min/measure.mjs minify                   # dist/minify: src/js/Minify.zig as a filter
node min/measure.mjs test && node min/measure.mjs fuzz   # §2: 298 checks, and the random test
node min/tools/mutants.mjs                    # §2: the random test catches all ten mutants
node min/measure.mjs size                     # §3, §4.1, §4.4, §5
node min/measure.mjs release                  # §5, the real compiler
node min/tools/trials.mjs                     # §4.2
node min/tools/order.mjs order min/steps/10-hand.js dist/o.js   # §4.3: reproduces 11-order.js
node min/tools/order.mjs names min/array.min.js                 # §1.5
node min/tools/a3.mjs                         # §7, the A3 rows
node min/brotli-probes.mjs                    # §1
node min/append-bench.mjs                     # §4.1, appending onto a trie
taskset -c 10 node min/tools/flat-bench.mjs   # §6.2
taskset -c 10 node min/tools/copy-bench.mjs   # §6.3
node min/measure.mjs bench 10 original.js array.min.js rewritten.js \
  flagged/build-by-append.js flagged/cow-copy-by-slice.js   # one round; the report ran five, interleaved
node min/measure.mjs tables                   # §6
```

Files: `min/original.js` (stage 0), `min/steps/` (the ledger), `min/rewritten.js` (§8's rules,
readable), **`min/array.min.js` (the smallest correct payload)**, `min/flagged/`, `min/Array.beni`
(the scenarios' `Array` with the three host-side exports declared), `min/minify.zig`,
`min/rename.mjs` (A2's prototype), `min/tools/`, and the raw timing cells in `min/results.jsonl`
(§6.1, five rounds) and `min/results-focused.jsonl` (§6.1's re-run; `RESULTS=min/results-focused.jsonl
node min/measure.mjs tables`).
