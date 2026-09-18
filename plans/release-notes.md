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
