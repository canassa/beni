## 2026-10-29 05:34 CET — Ownership v2: cold re-check, cursor links, apart aggregates

**What I did**

- **#1104 (PR #1148, merged).** A declaration stopped at the summary-size limit is checked again alone in fresh tables. It is refused only if that run is stopped too, and the dump prints cold accounts. The window where a warm run fits and the cold run does not is filed as #1147.
- **#1146 (PR #1149).** `linkArgs` now builds the snapshot with a builder per route position, an active-frame column and an argument cursor memoised per path. The X_k chain went from 9.4 M records to 25 568. A differential test shows the snapshot is identical to the root-path replay's.
- **#1121, first part, and #1140 (PR #1150).** `Cond.Agg`, a persistent apart aggregate, with `reachAgg` per node, `Radix.news`, group predecessors for read-off's `apartImage`, and a trie-shaped `ofSet`. T, W and the `Js.from` tower are now n log n. K is not: its cost is `dagKappa` per read context.
- **#1122, the S3a half (PR #1151).** The summary printer prints every route to a cell, and a built node met again as a reference to its first route. The block was already right, and a test now pins it.

**What I learned**

- A one-step growth check (`Shape.rank` finite) is not a cycle test: a recast has no rank. Find cycles with the walk itself.
- An atom set's canonical `and` chain was the hidden quadratic once the apart groups shared their cells. Make the canonical form follow the persistent set's own structure.
- K, #1098's lazy internal positions sets and #1128's path-multiset primitive are each a subsystem, not a patch. K's union reads need the primitive's choice semantics. Lazy positions sets change what `Shape.cells` means for about a hundred readers.
