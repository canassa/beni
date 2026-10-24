## 2026-10-25 00:53 CEST — a fold keeps only what its callback keeps (#749)

**What I did.** Fixed #749 in `src/own/Ownership.zig`. A fold whose callback put an inner list
of its accumulator in queued work refused every write of the accumulator. Three changes:
`callbackEscapes` escapes only the part a callback keeps, as a callee's own `E` already did;
a supply of a previous callback result is instantiated at the call's depth (`keptCells`), so
the escape lands on the cells the caller gets back; `returnsOwned` reads a storage write's
extent, so an escape strictly below the written collection does not refute ownership. Removed
the dead `list_only` escape. Summary blocks advance to 38. New fixtures `FoldKeepsInner` and
`FoldKeepsInnerRefused`; amendment in `ownership-checker.md` after the #670 one.

**What I learned.** The whole-value escape was not only coarse; it hid a lost escape. Master
accepted `List.update rows 0 …` at `rows[*]` after such a fold, because the escape went to cells
one callback depth further (another fresh namespace) than the result's. Only the root escape
refused the program. Removing the coarsening without fixing the depth would have been unsound.
