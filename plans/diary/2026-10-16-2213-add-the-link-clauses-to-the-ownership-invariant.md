## 2026-10-16 22:13 CEST — Add the link clauses to the ownership invariant

**What I did**

- #169, first slice: `Invariant` carries two link clauses. `LinksValid` records every stored link's structure (allocation order, nonempty source, one source per view). `LinkNamed` is the plan's narrowed clause: every array in the link component of an array that a live path or a permanent observer reaches has exactly its origins. Nothing protected means nothing required, so `readBoth(rest, xs)` keeps its distinct names.
- `ViewLinks.lean` proves `no_invariant`: the #169 pre-state admits no naming under the clauses. `LinkClauses.lean` proves the clauses under same links, allocation, nonempty writes and view creation, and that a per-link closed naming (`LinkClosed`) gives `LinkNamed`. The falsifier tests both clauses.
- A finding: the model's `put` writes with `write`, not `writeLinked`. A builder closed into a list, viewed and grown with `put` keeps a stale garbage view while the checker accepts the program and both runs agree. `ViewLinks.lean` checks it with `#guard`. So a view's contents are not a clause.

**What I learned**

- The plan rejects global origin closure under links because it makes `summary_sound` vacuous at a legal read-only split. In the main context the checker gives a view its source's origins plus a fresh site, so closure is always available there; the invariant only requires it where something protects the component.
- `protected` is a Lean keyword; a hypothesis with that name breaks the tactic parser silently until the next command. `List.nodup_singleton` is not in Lean 4.29; `List.nodup_cons` is.
- Lean's `#guard` is the kernel-free way to pin a model fact that the checker's well-founded recursion keeps out of `decide`.
