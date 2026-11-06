## 2026-11-06 03:43 CET — key an alias by the arguments its type shows

**What I did**

- Reproduced #1475 and #2074 on master `1550a68d61` with a ReleaseFast beni and `perf stat -e instructions:u`. #1475's diamond (`A_i a = A_(i-1) (A_(i-1) a)`, an unused private constructor of `A_n Int`) costs ×16 per four levels: 7.1 G instructions at n = 20, no end at n = 24. #2074's chains cost about ×3.5 when n doubles.
- Found that the two are different costs. #1475 is inside one read: `Builder.apply` keyed an alias by all its arguments' roots, and the outer application's argument is a new alias variable at every level. #2074 is across reads of zero-argument aliases. One change cannot fix both.
- Fixed #1475 (`checker-v2.md` §7.4, *Amended 2026-11-06*). New `AliasShape`: per parameter, forwarded, shown or hidden. `Injective.settle` settles it (pass 3). `Builder.apply` and `InterfaceTerms.Reader.expand` keep a second memo entry, `(alias, shown argument roots) → chain end`. Depth 64 now costs 19.0 M, near the floor.
- Added `check/good/AliasDiamondChain` (red without the fix: the case timed out), `check/bad/AliasSharedByShownArguments` (golden equal to master's output), and a `test-perf` scenario at depth 100 / 200.
- Opened #2121: ownership v2 costs 4^n on a USED value of such a type, on master and on the fix alike (`own2.Groups.Adapter.ofTerm`).
- Asked the owner `check-alias-chain-q1` for #2074: accept the n² cost in words, or design shared ground types across five phases (readings, generalization, instantiation, type keys, ownership v2).

**What I learned**

- An alias's links are invisible: `TypeStore.resolved` compresses every chain to its end, and `Render` prints an alias by name and arguments. So two applications whose SHOWN arguments match are one type that prints the same, and a read can share the chain end. Forwarding aliases (identity diamonds) show nothing at all.
- A `run/` fixture gets a v1/v2 ownership parity dump in the gates. A program that v2 cannot check fast cannot be a `run/` fixture; put it in `check/good/`.
- `perf stat -o <file>` with an empty `<file>` takes the next argument as the output file. My first measure script overwrote the beni binary that way. Check the output path before the run.
- `beni check` without `--no-cache` writes a `.beni-cache` beside the file. One left in `tests/corpus/check/bad/` failed the corpus (`MissingDiagGolden`).
- The rules test refuses a hash map keyed by a dense id (a row index): use `stamped.Column`.
