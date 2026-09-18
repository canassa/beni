# `--release`: the measurements behind `backend.md` §9's *The release optimiser*

Raw numbers only. The decisions they support are in
[`backend.md`](../docs/design/backend.md) §9; this file is where the figures live so that
section can cite rather than tabulate.

**Method.** Binary built from `e407c10` (`zig build`, Debug) in a throwaway worktree. Every
build tree comes from `node bench/size.mjs --keep`, so each program is built exactly as the
size benchmark builds it — its own project directory, `--platform=node`, `--library` for a
corpus root that declares no `main` (`bench/corpus`). The candidate passes were then
**hand-applied to the emitted `.mjs`** by a scratch tool (a tokenizer, five line-level
rewrites and a scope-aware renamer) and the trees re-measured with the same compressors
`bench/size.mjs` uses: `zlib.gzipSync` level 9 and `zlib.brotliCompressSync` quality 11,
window 22, over the concatenation of the emitted files in sorted path order.

`*.foreign.mjs` files are **included in every total and transformed by nothing** — that is
the shipping rule (a sibling is hand-written and copied verbatim, `backend.md` §2), and the
cost of it is table G.

**Correctness check.** With every pass applied, all **100** `tests/corpus/run/` programs
still print their `.expected` byte for byte and exit 0. That is what makes these numbers
measurements of the specified transformation rather than of a broken one.

Machine: the same one as `bench/README.md`. Date: 2026-09-18.

---

## A. Dev today against the release stack

The release stack is item 1 (zero-use drop + single-use inlining of compiler temporaries),
item 2 (scope-aware short names in emission order), item 3 (compact printing) and item 5's
surviving half (variable joining).

| tree | dev raw | dev gzip | dev brotli | rel raw | rel gzip | rel brotli | Δ brotli |
|---|---:|---:|---:|---:|---:|---:|---:|
| floor (`Empty`, 5 files) | 2,147 | 1,013 | 833 | 1,874 | 949 | 783 | −6.0% |
| `run/Dictionaries.beni` (13 files) | 31,495 | 8,237 | 7,008 | 19,971 | 6,774 | 5,847 | **−16.6%** |
| `bench/corpus` (25 files, `--library`) | 126,436 | 25,659 | 21,840 | 57,069 | 17,198 | 15,055 | **−31.1%** |
| all 102 trees, summed | 1,543,853 | 502,514 | 433,638 | 1,253,028 | 462,798 | 400,086 | −7.7% |

Raw falls 36% on `Dictionaries` and **55%** on `bench/corpus`. The summed corpus row is the
least interesting of the four: 100 of its 102 trees are three-kilobyte `run/` fixtures whose
bytes are mostly the unminifiable floor, counted 100 times.

## B. Each pass alone, on `bench/corpus` (brotli 21,840 base)

| stage | raw | gzip | brotli | Δ brotli |
|---|---:|---:|---:|---:|
| dev build | 126,436 | 25,659 | 21,840 | — |
| + zero-use drop | 126,397 | 25,656 | 21,824 | −16 |
| + single-use inlining | 118,947 | 24,149 | 20,795 | −1,045 (−4.8%) |
| compact printing alone | 95,841 | 23,329 | 20,414 | −1,426 (−6.5%) |
| short names alone | 90,762 | 19,910 | 16,899 | −4,941 (−22.6%) |
| the whole stack | 57,069 | 17,198 | 15,055 | −6,785 (−31.1%) |

The ranking of §9's list holds on our own output with one change: names are worth **more**
than the compress layer here, not less, because a dev name is `Module$base$tag` and Elm's
delegated baseline had nothing to compare against on that axis.

## C. Item 1 — single-use inlining, isolated

The stack with and without the single-use half, everything else identical:

| tree | without | with | Δ brotli | Δ raw |
|---|---:|---:|---:|---:|
| `bench/corpus` | 15,491 | 15,079 | **−412 (−2.7%)** | −2,360 |
| `Dictionaries` | 5,987 | 5,864 | **−123 (−2.1%)** | −540 |
| 102 trees | 402,216 | 400,360 | −1,856 | −7,772 |

(Measured against `t4`, the stack without item 5, so item 5's numbers in table E are
marginal against the same baseline.)

**The wider licence buys almost nothing.** Allowing any right-hand side, not only an atom or
a member chain, and requiring the use on the very next statement:

| tree | RHS is a read | RHS is anything | Δ |
|---|---:|---:|---:|
| `bench/corpus` | 20,795 | 20,705 | −90 |
| `Dictionaries` | 6,749 | 6,764 | **+15 (worse)** |
| 102 trees | 429,370 | 428,849 | −521 |

## D. Item 1 — the zero-use half

Over all 102 trees the zero-use drop removes **39 raw bytes, in exactly one declaration**:
`bench/corpus/ExprParser.beni`'s `tokenizeChars`, where a `c :: rest` row binds `rest` and
the body reads the whole list instead (`const rest$14 = chars$1.b;`). With single-use
inlining also running the difference is 12 raw bytes and **0** compressed.

## E. Item 5 — each rewrite, marginal against the rest of the slice

Baseline: dead + inline + names + compact, **no** item 5. 102 trees:
raw 1,256,052 / gzip 463,027 / brotli 400,360.

| rewrite | Δ raw | Δ gzip | Δ brotli | `bench` Δ br | `Dict` Δ br | verdict |
|---|---:|---:|---:|---:|---:|---|
| `const a=1,b=2` joining | −3,024 | −229 | **−274** | −24 | −17 | **in** |
| `if(c){return a}else{return b}` → `return c?a:b` | −446 | +30 | **+38** | +18 | +7 | **out** |
| `if(c){x=a}else{x=b}` → `x=c?a:b` | −13 | −10 | −8 | 0 | 0 | **out** — fires three times in the corpus |
| `if(c){return a} return b` → `return c?a:b` (`if_return`) | −359 | −4 | **+18** | — | — | **out** |
| joining + return-conditional together | −3,470 | −199 | −201 | — | — | worse than joining alone by 73 |

Report 12 §2.5 measured `conditionals` at −71 brotli and `if_return` at **+6** on a 15 kB
artifact; our own output agrees in sign on `if_return` and disagrees on `conditionals`,
which is what §7's statement-form lowering changed — the arms it would collapse now hold
`const` prologues and `return`s that a ternary cannot.

## F. Item 2 — the name order and the namespace shape

Renaming alone, over 102 trees (brotli):

| scheme | brotli |
|---|---:|
| one whole-program namespace, frequency-ranked | 414,216 |
| one whole-program namespace, emission order | 414,337 |
| per-declaration local namespaces, frequency-ranked | 409,338 |
| per-declaration local namespaces, globals by frequency + locals in emission order | 408,956 |
| **per-declaration local namespaces, emission order throughout** | **408,538** |

Inside the full stack the same ordering holds: 400,907 (frequency) / 400,753 (mixed) /
**400,360** (emission order). On `bench/corpus` alone: 15,216 / 15,104 / **15,079**.

Reusing the alphabet per declaration is worth **4,878 brotli bytes** over one flat
namespace; emission order is worth a further **800**. Frequency ranking loses on this
output at every size measured.

## G. What the siblings cost, and it is the floor

`*.foreign.mjs` is hand-written JavaScript copied verbatim and is never touched:

| tree | raw total | generated | sibling | sibling share |
|---|---:|---:|---:|---:|
| floor (`Empty`) | 2,147 | 504 | 1,643 | **76.5%** |
| `Dictionaries` | 31,495 | 17,722 | 13,773 | **43.7%** |
| `bench/corpus` | 126,436 | 111,456 | 14,980 | 11.8% |

After the release stack the generated half of `Dictionaries` falls 17,722 → 6,198 (−65%)
and of `bench/corpus` 111,456 → 42,089 (−62%) — at which point the siblings are **69%** and
**26%** of the release output respectively. The floor's release size, 1,874 bytes, is 1,643
bytes of sibling and 231 bytes of compiler output.

## H. Throughput, today

`zig build bench -- --generate=100000`, ReleaseFast, this machine:

| phase | figure |
|---|---|
| emit | 633 modules, 3,086,421 JS bytes, 54.15 ms, **54.4 MB/s**, 1,914,880 lines/s |
| whole cold build | **179.6 ms** for 100,159 lines (§13's budget is < 800 ms) |

## I. What a second `run/` pass costs

One serial pass of all 100 `run/` programs — build, then `node out/main.mjs` — with the
Debug binary: **15.4 s** wall, of which 11.1 s is the compiler and 4.3 s Node startup.
`zig build test-blackbox` is 67 s wall today at about 2.1× parallelism, so a second
`--release` pass of the whole `run/` corpus adds roughly **7 s, about +11%**.

## J. Whitespace: where the newlines go

Compact printing with no newline at all against compact printing with one newline after
every top-level declaration:

| tree | no newlines | newline per declaration | cost |
|---|---:|---:|---:|
| `bench/corpus` | 20,414 | 20,435 | +21 brotli |
| 102 trees | 426,818 | 426,858 | +40 brotli |

Two thousand raw bytes across the corpus and 0.1% of brotli, for output whose stack traces
still name a declaration by line.

---

# Slice 2: the measurements behind `backend.md` §9's *Item 4 — field ambiguation*

**Method.** Binary built from `f005a70` (`zig build`, Debug) in a throwaway worktree. Build trees
from `node bench/size.mjs --keep`, whose `out-release/` half is the shipping `--release` output of
this binary; the candidate renamings were **hand-applied to those `.mjs` files** by a scratch tool (a
JavaScript tokenizer, an object-literal/member classifier and a property renamer) and the trees
re-measured with `bench/size.mjs`'s own compressors — `zlib.gzipSync` level 9, `zlib.brotliCompressSync`
quality 11 with a size hint, over the concatenation of every `.mjs` in sorted relative path order.
`*.foreign.mjs` is in every total and transformed by nothing, as in table G.

The base column reproduces `bench/size.mjs` exactly (`bench/corpus` 55 593 / 17 144 / 15 017), which
is what makes the deltas deltas.

**Correctness check.** With every field renamed, **103 of the 107 `run/` programs** print their
`.expected` (or `.release-expected`) byte for byte. The four that do not are listed in M.

Machine: the same one as `bench/README.md`. Date: 2026-09-18.

---

## K. The two schemes, on the trees that matter

(i) every distinct record field name gets its own short name, frequency-ranked. (ii) two names share
a short name iff no record carries both — greedy colouring in descending frequency, source text as
tie-break.

| tree | base raw | base gzip | base brotli | (i) raw | (i) gzip | (i) brotli | (ii) raw | (ii) gzip | (ii) brotli |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| floor (`Empty`, 5 files) | 1,880 | 950 | 789 | 1,880 | 950 | 789 | 1,880 | 950 | 789 |
| `run/Dictionaries.beni` (13 files) | 19,836 | 6,773 | 5,860 | 19,836 | 6,773 | 5,860 | 19,836 | 6,773 | 5,860 |
| `bench/corpus` (25 files, `--library`) | 55,593 | 17,144 | 15,017 | 55,194 | 17,059 | **14,910** | 55,194 | 17,038 | 14,931 |
| 109 trees, summed | 1,363,169 | 504,668 | 436,547 | 1,362,322 | 504,397 | 436,230 | 1,362,322 | 504,349 | **436,227** |
| synthetic, 24 records × 10 fields | 28,797 | 8,018 | 6,734 | 19,617 | 6,748 | 5,599 | 19,201 | 5,917 | **4,999** |

Deltas in brotli: `bench/corpus` **−107 (−0.71%)** for (i) and **−86 (−0.57%)** for (ii); the corpus
total −317 and −320 (**−0.07%**); the synthetic −1,135 (−16.9%) and **−1,735 (−25.8%)**.

**(i) beats (ii) on `bench/corpus` by 21 brotli** and ties over the corpus. (ii) wins only on the
synthetic, where (i) captures 65% of its win. With 18 field names and a widest record of 8,
colouring saves no characters and only scatters the token stream.

## L. Why: the field-name byte share of the generated half

`*.foreign.mjs` excluded, because nothing renames it. "name bytes" is `len(name) × occurrences` over
record-literal keys and member reads.

| tree | distinct fields | occurrences | name bytes | generated bytes | share |
|---|---:|---:|---:|---:|---:|
| floor (`Empty`) | 0 | 0 | 0 | 237 | 0% |
| `run/Dictionaries.beni` | 0 | 0 | 0 | 6,063 | **0%** |
| `bench/corpus` | 18 | 96 | 495 | 40,613 | **1.2%** |
| synthetic, 24 × 10 | 120 | 1,008 | 10,604 | 18,810 | **56%** |

`Dictionaries` contains **not one record literal** — it is a red-black tree of tagged objects. The
brotli win tracks this share almost linearly, which is the number to re-measure before reopening
item 4: **~5% is where it starts paying.**

The synthetic is `24` record type aliases of `10` fields drawn from a pool of 120 realistic camelCase
names, each with a constructor, a field-by-field `describe`, a record update and a derived `==`,
built `--library --release`. It is the ceiling, not a prediction: generated declarations are more
self-similar than hand-written ones.

## M. What noticed, and it is only `Debug`

The four `run/` programs that change under a blanket rename, each of them a printed record:

| fixture | expected | with fields renamed |
|---|---|---|
| `DebugLog` | `{ name = "Ada" }` | `{ a = "Ada" }` |
| `EvalOrderLiterals` | `{ alpha = 2, mid = 0, zed = 1 }` | `{ a = 2, c = 0, b = 1 }` |
| `EvalOrderRecordFields` | `{ inner = { ax = 3, yy = 2 }, outer = 1 }` | `{ a = { a = 3, b = 2 }, b = 1 }` |
| `QuestionOrder` | `Ok { alpha = 2, zed = 1 }` | `Ok { a = 2, b = 1 }` |

Nothing else in 107 programs: `Basics.eq`'s `Object.keys` walk compares two values of one type and so
sees one colouring, and `List.eq`/`compare` read only `.$`/`.a`/`.b`.

**Two rewrites the tool got wrong before it got them right**, both worth recording because a real
implementation can make the same two mistakes:

1. `=>{` is an arrow **body**, not an object literal. Treating it as one renamed a §8 loop **label**
   and produced `SyntaxError: Undefined label 'c'` in 61 of 107 programs.
2. A **tuple** is a `$`-free object whose keys are the positional slots `a`, `b`, `c`… (§4), which is
   textually indistinguishable from a record. Renaming a tuple's third slot to `a` made
   `run/Tuples` print `5` and `8` where it should print `starts at zero` and `6` — a wrong answer,
   not a crash. In the compiler the lowerer knows which it built; the printer does not.

## N. Throughput, today

`zig build bench -- --generate=100000`, ReleaseFast, this machine, at `f005a70`:

| phase | figure |
|---|---|
| emit | 633 modules, 3,086,683 JS bytes, 48.08 ms, **61.2 MB/s**, 2,157,307 lines/s |
| whole cold build | **153.7 ms** for 100,159 lines (§13's budget is < 800 ms) |

Both faster than table H's 54.15 ms / 54.4 MB/s and 179.6 ms, on the same machine with `--release`
now in the binary — the release passes cost the dev build nothing.
