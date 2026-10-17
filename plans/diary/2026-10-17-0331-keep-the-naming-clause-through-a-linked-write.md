## 2026-10-17 03:31 CEST — Keep the naming clause through a linked write

**What I did**

- #169, fourth slice: `LinkedWriteStep.linkNamed_after_writeLinked` and its `liveCells` form. The naming clause of the invariant survives a successful, demand-guarded linked write of a live receiver with the same naming, for the continuation's uses. An array protected after the write was protected before it: a new path would pass through the written component, which the Unescaped test keeps from every observer and the Dead test from every holder that stays live.
- `reaches_decompose`: a path in a heap that agrees with another outside a set of arrays either exists in the other heap or first meets the set. `namesAt_mem_paths_general`: the names at any path of any abstract are drawn from its recorded paths, closures included. `namesAt_atPath_in_liveCells` ties them to the checker's live cells.
- Recorded the open half: `LinksValid` after the splice needs the contents arithmetic.

**What I learned**

- The protection transfer needs no contents of the written component, so the frame lemma of `LinkedWriteFrame` is enough for the naming clause; the contents matter only for link validity.
- A live use's path is a field path, which `projectVal`'s success proves, and that is what lets the paths of the abstract at that path shift back into the whole abstract's paths.
