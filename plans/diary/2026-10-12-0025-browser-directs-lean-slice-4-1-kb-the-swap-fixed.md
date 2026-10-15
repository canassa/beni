## 2026-10-12 00:25 CEST — browser-direct's lean slice: 4.1 kB, the swap fixed

**What I did.** Made the compiler emit research 70 §7's lean direct where it keeps the
guarantees: one rank-correct matcher in the reconciler (browser-tea's make order and moves kept),
one loop that makes rows, a swap checked once after both writes (`Direct.exchange`), the row
carrying its list's number instead of the descriptor so the release optimiser specialises the
runtime, `Direct.on` for listeners, the dispatch queue only on pages that can re-enter, short
release mount errors. Specified in `browser-direct.md` (two amendments, and the owner's §13
amendment withdrawing the 30 % `select` test), fixtures `ExchangeRows`, `ReconcileMoves`,
`emit/release/direct/TableSwap`, one batch on seven subjects, research 73.

**What I learned.** The bundle went 4 524 → 4 080 B and every operation is at or under S3; the
swap is now vanilla's, both modes. The 2.9 kB of the prototype was not reachable: it had dropped
rank-correct duplicates, the oracle's move order (P3's moves differ in focus from browser-tea on
eleven pages of the 50-seed fuzz sweep, in both directions), the defect guard and multi-program
mounting. Keeping the descriptor from escaping to the DOM was worth more than any hand edit: the
optimiser's facts then fold the runtime to the page. The page fuzzer's driver cache grows to
100 000+ entries in a sweep and then blows a gate's instruction budget; delete it after a sweep.
The release optimiser can declare one name twice in a `let` run after a fold: reduced to a
20-line program, CK-222, red in `tests/pending/run/ReleaseRedeclared`.
