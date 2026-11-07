## 2026-10-31 00:51 CET — own2: a taken result is materialised at the call

**What I did**

- Issue #1393: v2 refused `put b i (traverseAt a k)` `disjoint`, where v1
  accepts it and relies on `sep π1[*] π5[*]` and `excl π1`. With S3b slice 4a
  (#1395) this refuses `List.reverseHelp` (core List 1212:38).
- Root cause: `Calls.Grafter` mapped every class cell that is neither a
  parameter, `result`, `esc`, `site`, `shared` nor `⊤` to `⊤`. A row's
  `taken` result is `elem(π1·ρ)` (`Rows.takenElem`), so the element came back
  as `⊤`. `⊤` reaches every cell, so the write to `b` found another operand
  that reaches it. The element's type (a type variable) did not matter:
  `List (List Int)` elements were refused the same way.
- Fix: `Grafter.takenImage` maps a row's `elem(πᵢ·q·ρ)` to the element the
  call materialises out of the actual, as `Transfer.bindList` does for a list
  pattern. That is `elem(c·ι)` per symbolic container cell, under a split made
  at the call with κ the contents' at `q[*]`, plus the actual's other contents.
  It is used in `imageCells`, `eagerParts`, `viewLeaf` (through `mapInto`),
  `cellsOf` and `reachImage`. The stored list's κ now carries
  `apart [π1[*]] [π3[*]], excl π1[*], excl π3[*]`, the same as for
  `[ x, …_ ]`. Specified in `ownership-v2.md` §2.11 item 6, *A taken result*.
- Fixtures `ownership/core/TakenStored` and `TakenStoredImported`. Each
  declares its own `takeAt` with `traverseAt`'s row, then stores the element
  with `List.set` and `List.push`. The callee lines fail on master. One list
  passed as both arguments is refused; distinct or fresh lists are accepted.
- Raised `Calls.zig`'s §5 line target from 1 630 to 1 680. The file was at
  1 620 and the change adds 51 lines.

**What I learned**

- Outside the two new fixtures, v2's dump does not change on master for any
  ownership fixture, run fixture or core. A taken result reached only
  declarations that v2 did not check yet.
- On `origin/own2-s3b4a` with this change, core List 1212:38 is
  `accepted param`, v1's verdict. Its corpus fails only on the stale
  known-list entry for 1212:38, which #1395 must drop when this lands.
- `dump --stage=ownership` on `LevelPlacesCall` and `LevelPlacesKinds`
  reports SafeAllocator leaks on master as well: #1396.
