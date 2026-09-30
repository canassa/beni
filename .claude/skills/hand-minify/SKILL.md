---
name: hand-minify
description: Hand-minify JavaScript for size AFTER compression (brotli 11 first, gzip 9 second) — beni's core/ siblings, platform runtimes, emitted code and golfed probes. Use whenever the owner asks to hand-minify, hand minimize, minimise by hand, golf, code-golf, "make this JS smaller", "shrink this file", "squeeze bytes out of", "cut the brotli bytes", "make it compress better", "gzip/brotli-friendly JavaScript", or to price a minifier transformation before building it into src/js/Minify.zig. Teaches the measure-one-change-at-a-time method with a ledger, how brotli and deflate price JavaScript, a ranked catalogue of techniques with before/after and measured effect, the hazards, and where each technique belongs in beni's release pipeline.
---

# Hand-minifying JavaScript for compressed size

The target is **brotli-11 bytes of the exact bytes that ship**, gzip-9 second, raw
bytes a diagnostic only (`backend.md` §13). Raw bytes do not predict compressed
bytes: in beni's own measurements four edits that *saved* raw bytes *cost* brotli
bytes, and 94 raw bytes of `const` cost 8 (research 40 §4.2). Read
`docs/design/research/40-array-sibling-under-brotli.md` §0, §1 and §8 before a
serious pass; this skill is its method, generalised, plus the outside literature.

## 1. The method

### 1.1 Measure the shipped bytes, every time

Measure what the user downloads: for a sibling or runtime that is **the file after
beni's own `--release` compactor** (`src/js/Minify.zig`), not the file on disk,
because the compactor already strips comments and whitespace and renames locals —
a hand edit it would have made anyway is worth 0. For an app, measure every file
the page loads, concatenated (`bench/ui/sizes.mjs`'s method).

The one command (Node 24's zlib; `direnv exec` needs an allowed `.envrc`, so from a
fresh worktree run it with the main checkout's path, or `direnv allow` first):

```sh
direnv exec . node -e 'const z=require("zlib"),f=require("fs");for(const p of process.argv.slice(1)){const b=f.readFileSync(p);console.log(p,"raw",b.length,"gz9",z.gzipSync(b,{level:9}).length,"br11",z.brotliCompressSync(b,{params:{[z.constants.BROTLI_PARAM_QUALITY]:11,[z.constants.BROTLI_PARAM_SIZE_HINT]:b.length}}).length)}' FILE...
```

It reproduces research 40's figures exactly (`bench/arrays/min/array.min.js`: raw
2 548, gzip 1 169, brotli 1 093). Quality matters: the same file is 1 140 at
brotli 5 and 1 093 at 11; the window (lgwin 16 or 22) does not once it covers the
file (research 40 §1.4). Never quote a size at another quality without saying so.

### 1.2 One change at a time, with a ledger

1. Record the baseline: raw / gzip-9 / brotli-11.
2. Make **one** change. Measure. Write a ledger row: `step | technique | raw | gz | br | Δbr | kept?`.
3. Keep it if brotli fell by more than the noise; revert it otherwise.
4. **Noise is ±5 brotli bytes** for any small edit on a 1–3 KB file (research 40
   §9). A Δ under 10 is a direction, not a magnitude; re-price a doubtful edit
   alone against the final file (`bench/arrays/min/tools/trials.mjs` is the
   pattern: a table of single text edits, each applied alone, each priced).
5. Keep the readable steps as files (`steps/00…NN`), each the one before plus one
   technique, so every byte is attributable and every step is re-testable.

When the same edit is priced on two nearby files and the two disagree by up to 17
bytes (research 40 §4.2), only the sign and the large magnitudes carry information.

### 1.3 Behaviour after every step

- A **differential test** against the original: the same operations on random
  inputs, results compared by value *and* representation *and* identity
  (`bench/arrays/min/measure.mjs fuzz` is the model; check it by mutation — ten
  one-token mutants, all caught — because an LCG's low bits for `% n` caught only
  three of ten).
- For anything beni ships: `zig build gates` (the `run/` corpus runs every
  program twice, dev and `--release`, and `browser/` pages too), and
  `zig build test-run-hashes` after touching `core/` or a runtime.
- For a sibling: `boundary.md` §4's four checks must still pass — **never change
  an export's parameter list** (check 4 counts it) and keep `export const x = (…) =>`
  per export.

### 1.4 Never trade speed silently

Every smaller-but-different algorithm is timed on its hot path before it is kept,
or kept out and flagged. Research 40 §4.4 rejected −36 bytes because the first
write became 4–16× slower, and a 15–18 % slowdown from routing a hot read through a
late-bound binding (§5 rule 2). `flat()` was the shortest flattening and 2.4–3.8×
slower. Put the reason in a comment next to every speed-motivated line so the next
pass does not "simplify" it.

## 2. How the compressors price JavaScript

**Deflate (gzip, RFC 1951).** LZ77 over a **32 KB window**, matches of **3–258**
bytes, then Huffman codes per block. A distance costs a code plus 0–13 extra bits,
growing with log2(distance). There is no memory of past distances and no
dictionary. So: repeats must be ≥3 bytes and within 32 KB; nearer is cheaper; a
small alphabet (fewer distinct byte values) gives shorter Huffman codes.

**Brotli (RFC 7932).** LZ77 plus context modelling plus a static dictionary:

- **Commands** are *insert n literals, then copy m bytes from d back*; the shortest
  copy is **2 bytes**; the window reaches 16 MB.
- **A distance cache** of the last four distances: codes 0–15 mean "last,
  second-last … or last ± 1–3", with no extra bits, and an insert-and-copy symbol
  in 0–127 *implies* the last distance with no distance symbol at all. **Parallel
  code — two functions whose matching parts sit at the same offset from each
  other — makes every copy after the first nearly free.** This is the single most
  important fact for a writer.
- **Context modelling**: each literal's code is chosen from the two bytes before
  it. A literal predictable from its left context (`a.` then `length`) costs a
  fraction of a byte; an unusual byte in an unusual place costs more than one.
- **A 122 KB static dictionary** of English and web words with 121 transforms.
  `function`, `return`, `length`, `.length`, `slice`, `push`, `null`, `true`,
  `false`, `while`, `this.`, `prototype`, `undefined`, `document`, `window` are in;
  `const`, `let`, `export`, `=>`, `===`, `concat`, `Array`, `isArray` are not.
  **At beni's sizes it is worth a few bytes and nothing to write for**: a hit only
  saves the word's *first* occurrence (research 40 §1.3, probes in
  `bench/arrays/min/brotli-probes.mjs`).
- **Quality 11 parses optimally** (Zopfli-style), so the encoder, not you, picks the
  cheapest path among all matches — which is why order effects are real but
  unpredictable.

**What follows for both.** Compressed size is paid for by **what is distinct**.
Repeating an exact byte string is nearly free; the price is in what differs.
Appending a 79-byte statement's twin renamed at its top-level name only costs +13
brotli bytes; the same twin with its four locals renamed costs +39 (research 40
§1.5). esbuild's minifier is built on the same fact: it renames by frequency and
gives sibling scopes' parameters the same slots so `a,b,c` repeats across
functions, because "repeated sequences of characters will compress better than
unique sequences of characters".

## 3. The catalogue, ranked

Ranked by what they bought in beni's measurements, then by the literature. Every
figure is brotli-11 unless it says otherwise. "Compactor" means `Minify.zig`
already does it under `--release`: do not do it by hand in a shipped source file.

### Tier 1 — structure (tens to hundreds of bytes each)

**1. Write each walk once; merge near-duplicate functions.** Before writing a
loop, find the one it resembles and give that one a parameter (a stopping depth,
a direction, a callback). This is the only tier-1 technique that removes *distinct*
text, and distinct text is what compression charges for.

```js
// before: two walks that differ in where they stop
let setPath=(x,s,i,v)=>{…descend to leaf…};let pushLeaf=(x,s,i,l)=>{…descend to depth 1…}
// after: one walk with a stopping depth
let S=(x,s,i,v,d)=>{…descend until s==d…}
```

Measured: one path copy for every write −113 after terser; walks over one leaf
walk −45; one leaf descent for get and pop −46. Steps 01, 05 and 06 were 254 of
the 367 bytes the readable ledger saved; **no renaming comes close** (research 40
§4.1, §8 rule 1).

**2. Remove dead generality.** Cases the contract makes impossible, a
normalisation done twice, a dispatch repeated in each branch. Hoist the check
once (`if(i<0||i>=n)return a` before the representation switch, −33); replace
normalised indices by arithmetic. Each is a distinct piece of code gone. Check
the contract first: dropping `unsafeGet`'s dead bounds check bought 0 to +2 — the
bytes are only worth taking when the code is really distinct.

**3. Make readers not name write code (tree-shaking by mention).** beni's
compactor keeps a top-level statement iff a live statement *mentions* its name,
with no scope analysis. One careless mention keeps a whole subsystem. Route a rare
reader→writer call through a binding the writer sets (`let Grower;`), never a hot
read (research 40 §5: −213 for a read-only program; the late-bound hot read cost
15–18 %). Keep top-level names Capitalised and locals lower case so a local never
keeps a top-level unit alive by sharing its name — research 41 §5.4: a runtime local
named `map` kept the `map` export alive, 116 bytes.

**4. Consistent names and parameter order across functions.** `a` is always the
array, `i` the index, `v` the value, `x` the node, `n` the length, in the same
order in every signature. +13 against +39 for the same duplicated statement
(research 40 §1.5). esbuild and terser do this for locals automatically (sibling
scopes share slots); do it by hand for anything they cannot rename — top-level
names in parallel roles, property names you own, argument order.

**5. Identical statement shapes, and similar code adjacent.** Write parallel
functions as literal copies with the smallest possible diff, same operand order,
same spelling (`a.t.slice()` everywhere, not `a.t.slice(0)` in one place). Put
look-alikes where the matcher and distance cache find them. The best order is not
predictable: a hill-climb over 32 top-level statements found −21 bytes in an
order no rule predicts (research 40 §4.3, `bench/arrays/min/tools/order.mjs
order`). Legal only when no top-level initialiser reads another binding at load
time. Commit the found order with a comment that it is deliberate; do it once, for
a stable file that ships in the box, because it overfits one brotli version.

### Tier 2 — renaming and delivery (compactor territory)

**6. Rename bound names short, most-frequent first.** Research 40 A2: −87 to −109
on one file; −355 on the benchmark app (research 41 §3.4). **Built into
`Minify.zig`** (`rename`): injective, file-wide, token-level, never exported,
imported, global or property-position names. Hand work here is only for names the
compactor must keep, and for the source rule that makes its job possible (no name
used both as a binding and a property).

**7. One scope instead of many modules.** Twelve ES modules against one hoisted
file was the largest cause on the app (773 bytes, research 41 §0.2): every
`import`/`export` statement is distinct text. Built: `backend.md` §9, *One
scope-hoisted file under `--release`*. By hand, in a golfed file: merge files,
inline tiny modules.

### Tier 3 — spelling (0–30 bytes each, often noise)

These are the classic golf tricks. Under brotli most are worth ≤ the noise floor
because a two-byte saving inside a phrase that repeats is a zero-byte saving
(research 40 §0.2). Price each alone; keep the ones with a sign you trust.

| technique | before → after | brotli effect measured / expected |
|---|---|---|
| `const`→`let` file-wide | `const a=1` → `let a=1` | −8 to −20 (built: A3). **All or none**: per-declaration cost +9 because a file mixing both compresses worse (research 41 §3.4) |
| `(x)=>`→`x=>` | `(a)=>a.n` → `a=>a.n` | −18 on one file, +10 (noise) on another (built: A3) |
| drop `;` before `}` | `{return a;}` → `{return a}` | −14 / 0 (built: A3) |
| arrow constants over `function` | `function f(a){return a.n}` → `let f=a=>a.n` | a few bytes; also what check 4 counts most directly. `function` and `return ` are dictionary words, so the gain is smaller than raw suggests |
| joined declarations | `let a=1;let b=2` → `let a=1,b=2` | −2 to +15, and it **breaks elimination** (one unit keeps every name in it): keep one top-level statement per droppable unit (research 40 §4.2, §8 rule 3). Beni's `Print.zig` joins runs in *generated* code, where it pays |
| `==` for `===` where both sides are known numbers/strings | `a.s===5` → `a.s==5` | 6 raw and 9–12 brotli: switching back to `===` everywhere cost +9/+12, more than the raw bytes, because it disturbs the surrounding matches |
| newline per statement | `;\n` → `;` | +21 to +31 for a newline after every `;` (83 raw) |
| ternary / `&&` / `||` for `if` | `if(c)return x;return y` → `return c?x:y` | small, either sign; all of terser's `compress` (this plus inlining and dead branches) bought only 7–28 on a whole file (research 40 A7) |
| `!0`/`!1` for `true`/`false`, `void 0` for `undefined` | | raw −2/−3/−3, but `true`, `false`, `undefined` are dictionary words and repeat: expect ≤ noise. Measure |
| template literals | `"a"+b+"c"` → `` `a${b}c` `` | wins when there are two or more joins; neutral otherwise |
| shared constant | `1024` ×3 → `L=1024` | **+6 to +13**: a repeated literal is already a cheap copy, the binding is new text |
| helper constructor | `{n,s,r,t}` literals → `M(n,s,r,t)` | −13 to +17 depending on surroundings: noise, decide on clarity |
| dropping braces | `if(c){return a}` → `if(c)return a` | small; watch ASI (§4) |
| `for` shapes | `for(let i=0;i<a.length;i++)` everywhere, same spelling | the win is identical headers, not the shortest one; `for…of` is shorter but not the same speed on every engine — measure the hot path |
| destructuring vs property access | `let{n,s}=a` vs `a.n`,`a.s` | shorthand makes `n`,`s` both a binding and a property, which **blocks renaming** of them (research 40 A2); prefer `a.n` unless the names are already one letter |
| comparator tricks | ternary chain → `(x=f(x,y))=="GT"\|-(x=="LT")` | −4 raw, **+5** brotli: cleverness is distinct text |

### Tier 4 — what does not matter

- **Which short letter a unique name gets.** A 2 000-trial hill-climb over every
  bijection of 19 top-level names onto `A–Z` found **0** bytes (research 40 §1.5).
  Doubling each to two letters cost +52. One letter vs two matters; *which* does not.
- **Writing for the brotli dictionary.** Few bytes, first occurrence only.
- **Shortening a phrase that already repeats.** It is paid once.
- **Character-diversity tricks** (golf lore for deflate: one quote style, one case).
  Real under deflate's Huffman for tiny files; brotli's context modelling absorbs
  most of it. Do it only when it is also consistency.
- **Self-extracting packers** (RegPack, Roadroller). They beat zip in js1k/js13k
  because the contest counts the zip; a server sends brotli, which already does
  their job, and they cost decode time and memory at load. Not for beni's output.

### When short names *hurt*

- A rename that breaks a repeat: two parallel functions with parameters `(a,i,v)`
  and `(b,j,w)` cost more than both spelled `(a,i,v)`, even if every name is one
  letter.
- Scope-local freshness: a minifier that gives every local a globally unique name
  loses the repetition that sibling-scope slot reuse (esbuild, terser) gives; an
  injective file-wide renaming (beni's A2) relies on the *source* reusing names by
  role to get it back.
- Splitting a large scope into small ones can make the minified file *larger* raw
  and smaller compressed: 167 raw / 112 gzip against 157 raw / 129 gzip in one
  published measurement (Caolan, 2025), because each scope restarts at the same
  names.

## 4. Hazards

- **ASI.** A newline can only be removed where automatic semicolon insertion is
  not acting: after `return`/`throw`/`break`/`continue`/`yield`, before `++`/`--`,
  before a line that starts with `(`, `[`, `` ` ``, `+`, `-`, `/`. `Minify.zig`'s
  `newlineIsInert` is the exact rule; by hand, write the `;` and let the compactor
  drop it.
- **`/` as division or regex**: after `)` of an `if`/`while`/`for` head it is a
  regex. The compactor declines files it cannot decide; hand edits must not create one.
- **`this` and `arguments`**: `function`→arrow changes both. Also `new`-ability
  and hoisting (an arrow constant is in its temporal dead zone until evaluated —
  reordering top-level arrows is only safe when nothing calls them at load time).
- **Getters, proxies, `valueOf`**: dropping a "dead" property read or reordering
  two reads is not sound if a read can run code (terser's `pure_getters` is an
  assumption, not a fact).
- **`eval`, `with`, `new Function`, `class`**: any renaming is unsound; the
  compactor refuses `eval` and renames nothing in a file with `eval`, `with` or
  `class`.
- **Property renaming across a boundary.** Closure ADVANCED mode, terser/esbuild
  `mangle.properties` rename properties consistently only inside what they see;
  one `o["name"]`, one `defineProperty`, one other module or one runtime reading
  the field breaks it. In beni it is unsound for siblings: they share field names
  (`$`, `a`, `b`, `n`, `s`, `r`, `t`) with the emitter and runtime. Type-directed
  field renaming belongs to the compiler (`backend.md` §9 item 4), not to hand work.
- **Globals.** A renamed local that shadows `document`, `parent`, `name` breaks the
  free read elsewhere; `Sibling.isStandardGlobal` plus the host list is what keeps
  beni's renamer sound.
- **Exports and arity.** Never add a default parameter to an export to get a free
  local: check 4 counts it (`foreign_arity_mismatch`). Fine on internal helpers.
- **`concat` on an array with a named property** leaves V8's fast path: 52 µs
  against 7.7 µs to append 1 000 to 10 000 elements (research 42 §7.3). Copy with
  `slice` or a loop.
- **V8 shape changes**: building objects with different key orders or adding keys
  later ("one constructor for every node" is also a speed rule) makes call sites
  polymorphic; a byte-saving rewrite that changes object shapes, packs mixed types
  into one array or turns a monomorphic loop into a generic helper must be timed.
- **Spread and `apply` with huge arrays** hit engine argument limits (JSC ≈ 65 536);
  `[].concat(...leaves)` was faster and unsafe above ~2 M elements (research 40 §6.2).
- **Field identity is load-bearing** for beni's UI (CLAUDE.md rule 8): a rewrite
  that copies where the original returned its input (`slice` "just in case")
  breaks identity checks. The differential test must compare identity.

## 5. Feeding `Minify.zig` and the emitter

Hand work is research; the compiler is where bytes stay won. After a pass, sort
every kept technique into one of three bins and say which in the report:

1. **Already automatic** — don't do by hand in source: comments/whitespace,
   elimination by mention, A2 renaming, A3 (`const`→`let`, `(x)=>`, `;}`), one
   scope-hoisted file, joined `const` runs and short names in generated code
   (`Print.zig`, `Rename.zig`), local dead bindings and single-use inlining
   (`Opt.zig`).
2. **A token-level pass `Minify.zig` could add** — no parser, no scopes, a
   refusal for every case the tokens cannot decide (the compactor's contract,
   `backend.md` §9 *Hand-written JavaScript under `--release`*). Price it first by
   a text rewrite of the built tree (`bench/ui/anatomy.mjs`'s *hand-applied
   candidates*), then specify its soundness condition, then build it with a unit
   test per hazard. Research 40 §7 is the template (A2, A3, A5 order search).
3. **A source rule** for whoever writes `core/` and platform JavaScript — the
   ones the compiler cannot infer: write each walk once, readers never name
   writers, parameter names by role, capitalised top-level names, inert top-level
   initialisers, one statement per droppable unit. Research 40 §8 is the list; add
   to it rather than restating it.

Anything that needs a JavaScript parser (terser's `compress`: inlining, dead
branches, `if`→`&&`) is out for siblings: `boundary.md` §4's wall exists to avoid
one, and on a file written to the source rules it buys 7–12 bytes (research 40 A6/A7).

## 6. Harnesses in the repo

| tool | what it measures |
|---|---|
| `bench/size.mjs` | every corpus program, dev and `--release`, raw/gzip/brotli; the floor and the empty page lines |
| `bench/ui/sizes.mjs`, `bench/ui/anatomy.mjs` | the benchmark app against Solid 1: per file, leave-one-out, hand-applied candidates, minified alike |
| `bench/arrays/min/measure.mjs` | `minify` (Minify.zig as a filter), `size`, `test`, `fuzz`, `release`, `bench` |
| `bench/arrays/min/tools/trials.mjs` | single edits priced alone — copy it for a new file |
| `bench/arrays/min/tools/order.mjs` | statement-order and name-letter hill-climbs |
| `bench/arrays/min/brotli-probes.mjs` | dictionary-word substitution probes |
| `bench/arrays/min/tools/mutants.mjs` | proves the differential test catches one-token mutants |
| terser `compress:{passes:3,toplevel,unsafe_arrows,pure_getters},mangle:{toplevel}` | the reference bound (`npm ci` in `bench/arrays` installs it) |

Report a pass as research does: a stage table (raw / gzip-9 / brotli-11 / Δ), the
ledger, the flagged-not-taken list with their speed, and the bins of §5.

## Sources

- RFC 7932, Brotli Compressed Data Format — https://www.rfc-editor.org/rfc/rfc7932
- RFC 1951, DEFLATE — https://www.rfc-editor.org/rfc/rfc1951
- esbuild architecture, *Symbol minification* — https://github.com/evanw/esbuild/blob/main/docs/architecture.md
- esbuild API, minify and mangle props — https://esbuild.github.io/api/#minify
- terser README, compress and mangle options — https://github.com/terser/terser
- Closure Compiler, ADVANCED_OPTIMIZATIONS — https://developers.google.com/closure/compiler/docs/api-tutorial3
- Caolan, *Smaller JavaScript using gzip* (2025) — https://caolan.uk/notes/2025-03-18_smaller_javascript_using_gzip.cm
- subzey, *Few tricks on compressing js13k entry* — https://gist.github.com/subzey/b18c482922cd17693d65
- RegPack — https://github.com/Siorki/RegPack
- Roadroller — https://github.com/lifthrasiir/roadroller
- minification benchmarks — https://github.com/pfgithub/minification-benchmarks
- beni: `docs/design/research/40-array-sibling-under-brotli.md`,
  `41-release-bundle-against-solid-1.md`, `42-reference-counts-in-javascript.md` §7.3,
  `47-js-intrinsics-spike.md` §6, `docs/design/backend.md` §9, `src/js/Minify.zig`
