## 2026-10-31 09:07 CET — κ transport by correspondence (S3b slice 5a)

**What I did**

- Phase 1 found a design choice and stopped (#1447). The eager keying of #1408 (`leafEntries`) is the whole of #1428. Switched off, K was n log n again, but `GroupJoinShared` and its imported twin became wrong accepts. The manager chose option B: a projection correspondence plus a context read.
- Built option B. A join of alternatives keys `D = proj(joined, q)` alone, and every reader reaches it:
  - a caller: the view of a union, choice or positions template projects to the view of the template's projection, which is where `Calls.apply` already relabels the class's entry;
  - read-off: `Shape.proj` records each DAG it makes with its origins, and `Cond.projectedImage` maps `D` to the projection of its origin's image;
  - the printer: it carries the outermost DAG on its way and joins that projection's entry.
- Every join of alternatives now starts from its members' snapshots merged: `joinRes` and the supplies join, as the branch join always did (#1093). `widenValue` has one member: `propagate` keeps that member's entries at each walked position outside a fold.
- `Summary.eq` is `leq` both ways (#1094).
- `BlockRead.sameDag` compares canonical ids, so a projection decoded mirrored at every level is accepted. `noteOrigin` records the decoded projections.
- §2.9 *Keyed where a reader looks* is rewritten and carries #1406's argument. §2.11 and §3.4 have notes, and the 5a row is amended.
- Tests:
  - unit tests for #1406, #1093, #1094, the transport, a view's projection and a block round trip;
  - K counted at 10 / 40 / 80;
- After the rebase onto 4b, a view at a type variable's place hit `force`'s place assertion in `run/TailModConsMerge`; a view now projects to its template's projection only at the template's own place.

**What I learned**

- A transport over `(node, position)` pairs cannot be source-sized on K: its snapshot holds Θ(n²) entries in O(n log n) map nodes. The correspondence has to stay per node: node images plus projection origins.
- An eager correspondence at the call (projecting the call's view for each joined entry) doubled a caller's records (`c1` 3 930 → 7 023), because it forces the template's leaves. Making `proj` of a view of a DAG template return the view of the template's projection costs nothing at the call.
- K's block was already Θ(n²) in positions on master (2 542 / 9 882 at 40 / 80). Keying `D` doubles that, so at 160 the block passes the allowance and is not published, silently (#1450). The K test gates 10 / 40 / 80 for that reason. 160 also takes 2 s to check and 10 s to dump (#1426).
- The full cross-check fails the same five v1 panics as master. It also fails `MarkerAcross.keepRight`, which hits a limit under the cross-check only: master is at 65 004 of 65 536 there.
- `Rose [ r, r ]` costs about 18 % more (17 058 / 256 144 at 10 / 40). It is still quadratic and belongs to #1420.
- Merging a widened value's snapshot whole into the image collapses the image's folds: every built node there then reads `lost` (`joinFold` in `build_test.zig`). A lone member's entries are kept per walked position, never at a fold.
- Applying the correspondence to positions nodes (a literal's `together`) cost `doublingProduct` past its knife edge (`build_test.zig`'s "says why a summary is not printed"). A join of alternatives makes only unions and choices, so the correspondence, the view's projection and the printer's context are restricted to those two kinds.
