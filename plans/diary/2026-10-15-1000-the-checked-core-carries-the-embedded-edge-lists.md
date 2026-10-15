## 2026-10-15 10:00 CEST — the checked core carries the embedded edge lists

**What I did**

Took Jayson's decision on issue #94 (the cache lives in the checked
core, edge lists first) and built the first step on PR #118's branch.
The pack has a third row kind, `edges`: one row per embedded module and
per value of `--release` and `--schema-library`, keyed by the module key
and the two options (`src/js/EdgePack.zig`). A node in a row names its
module by package and dotted name, and a build resolves it with
`Graph.find`; a target in a module the build does not hold is dropped,
as the builder drops it. The maker builds the rows after each run's
check and skips modules an earlier run made; the pack stores two edge
rows with the same bytes once. A new counter, `edge_lists_embedded`,
and three black-box tests that build a program, a program that
suspends and a page with the embedded core and with a copy under
`--core-root`, and expect the same tree. `fast-compiler.md` §8 and
`backend.md` §9 amended.

**What I learned**

`run/Dictionaries` goes 180 → 152 million instructions, `run/Adt`
143 → 116, `browser/tea/ApiItems` 545 → 489 (629 on master),
`browser/direct/AfterRenderFocus` 489 → 431, `bench/corpus` 420 → 391.
On ApiItems the edge lists now cost 6 million: 5.8 million of reads.
The maker goes 4 622 → 5 137 million and the pack 3.20 → 3.38 MB. A
first version of the maker rebuilt core's rows in every run and hashed
every payload for the dedupe, at 7 049 million; the rebuild alone was
2.4 billion. The `if Js.development` guard uses a constructor index of
`maxInt(u32)` that no module has, now `Reach.never_ctor`; a range check
on rows must let it through. Reading release rows in a development
build makes a page's build stop on the safety wall, and the page tests
catch it.
