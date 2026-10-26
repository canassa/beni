## 2026-10-26 12:20 CET — Ownership v2 S3a: lists in one declaration

**What I did**

- Built S3a's walker behind `--ownership=v2` (#1015): `Calls` (a worded row's class grafted onto the call's arguments, κ instantiated), `Transfer` (literals, spread chains, `++` chains, tuples/records/constructors as containers, `let`, `case` and patterns with list splits, top-level values as `shared`, calls of worded rows), `Demands` (Known, Unescaped, Disjoint, Dead through a live inverted index over the persistent sets, cycle-anchor chains for `⟲`, Exclusive under a split), `Walk` (frame, use index, resolution, read-off), `Groups` (the place adapter over the checker's tables with constructor templates and a non-regular fold, the signature adapter, derived `eq`/`compare` classes, the word-kind check), `Message`, `Report`, the facade and `Enforce` (dump, Driver hook, block publication through the interface).
- A declaration with a construct S3a does not build (a lambda, a call of another declaration, a record update, …) gets the pessimistic class and reports nothing.
- The corpus walker compares `dump --stage=ownership --ownership=v2` with the golden's verdict lines where a fixture has a `.v2` file (or with its `.v2.ownership`). Green under v2: LaterRead, Spreads, SelfSpreads, ViewAliases, and three new red twins RoseAlias, MaybeTreeAlias, MutualAlias (red without the anchor chains, shown by disabling them).
- Split off #1069 for #1063/#1064 (Cond's observable-position frontier, exact propagation states).
- Found and fixed two use-after-reallocation bugs in S2 code: `Shape.map` of a delta read a column before a call that grows it; `Cond.propagate` iterated slices of a list it appended to.

**What I learned**

- Most of S3a's acceptance row needs S3b: Split, Nest, PathCut, ParamHole, DeeperLevel and MarkerAcross all have lines from calls of summarised same-module declarations (MarkerAcross a recursive group), RoseKidsHeld is defined by such a call, and StoredTwice needs `List.copy`'s word (#1052, approved).
- v2 is more precise than v1 in `Split.readAfter`: `List.length` reads no element, so writing one is accepted (#1072, the owner's).
- Growth is spent on source-sized work: ~96 records per straight-line statement, seven corpus owners above 10 % of the allowance (#1070). The primitives charge an account, not a lane.
- A symbolic cell in a built node's own cells stands for that object only; reading it as "everything below" made a list pattern's `rest` hold the element it does not.
