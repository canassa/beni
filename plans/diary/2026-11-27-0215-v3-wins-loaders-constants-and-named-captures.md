## 2026-11-27 02:15 CET — v3 wins the loader pages, a constant read once, and named captures

**What I did**

- Lane prec223, on the master merge of the v3 branch (merge216's `own3-merge216`, with
  `origin/ownership-v2-design-review` at 945ba6f4be and `origin/master` merged in). Re-measured
  v3 on the 425 `browser-inline` pages: 40 refused, the 38 safe pages of #2657 and the two live
  pins.
- **A decoding run answers what its worker built** (kernel §6 rule 14). A run of `Json.decode`,
  `decodeWith`, `decodeValue` with a derived codec of no argument, or of `Schema.read`,
  `readWith`, `parse`, `parseWith` of `S.schema ⊤`, whose definition has no `via`, check,
  parameter or module `codec` (`SchemaGraph.buildsFresh`), is read at the call's own result
  type (`Frame.decodedContract`): a new cell of its own site at each list and record slot below
  `Ok`, the input at a `Value`. Wins the nine loader pages. A first version reused the walked
  contract's site numbers, so a new cell was one of the issues' escaped cells; the sites now
  start past them.
- **A constant read once** (kernel §7): a private constant that one instruction names, in the
  body of another constant that runs once, is that reader's own. Wins `InitializationTransfer`.
  The reviewers found two holes, both fixed and pinned: browser-inline inlines a constant of
  markup at each use and runs it per render (`loaderRunsOnce`), and the backend makes a
  constant with a `where` clause a memo per evidence (`runsAtLoad`,
  `run/ConstantReadEvidenceLive`).
- **A capture of a named function** (kernel §6 rule 2): a lambda's call of a capture that a `let`
  binds to a top-level function is a call of that function's contract. Wins `NestedFoldValue`.
  `run/CellScopeCloseLive` gets two more refusals of its unsafe shapes.
- 38 → 27 refused pages; no page moved to refused; 0 faults in the oracle's four legs on the 11
  pages and on every probe; root dumps 0 accepted → refused; ledger 309 of 319 unchanged.

**What I learned**

- "Evaluated once" is a fact of the backend, not of the source: a constant can be inlined per
  render (markup) or memoised per evidence (`where`). Read the definition convention the lowering
  reads (`Convention.definitionOf`) rather than the shape of the declaration.
- The remaining 27 are designs, not fixes: handlers read at event time (needs a lowering report),
  closures that read a field when they run (needs the lowering to read at creation), the message
  rule (owner decided 2026-11-27, not built), and fold accumulators and function elements in
  lists (needs per-run fresh sites and code in data).
