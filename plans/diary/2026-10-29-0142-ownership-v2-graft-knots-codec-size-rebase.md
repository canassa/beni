## 2026-10-29 01:42 CET — Ownership v2: graft knots, codec size, a rebase

**What I did**

- #1143 (PR #1144): grafting a call result now defers a part whose image reads a pending knot (a union, a positions node, a recast, or a delta's base) until that knot is tied. Before this, a back edge onto a union's side recursed forever. Four more source-depth walks are now loops: `Printer.cell`, `Printer.label`, `Message.baseText` and `Groups.expandsToVariable`. `Summary.Table.join` and `leq` stay native, bounded by `Parse.max_depth`.
- #1132: CI failed after #1142 landed. I rebased the branch. `proj` of a recast now reads its built inner's part through the explicit stack (`recastPart`), not through a nested `proj` call. Shape's §5 line target is now 1 800.
- #1141 (PR #1145): a 1 000-level snapshot ran past the codec's lane. The writer walked the κ snapshot without counting it in S. It now counts each map, entry and link as it meets it. A counted test shows about 2× work per doubling, from 500 to 2 000 levels.

**What I learned**

- "Superlinear" was the wrong diagnosis. The work was linear, but the bound was computed from a size that left out the input being walked. When a lane breaks its bound, first check what S counts, and only then look for a quadratic loop.
- A rebase onto an explicit-stack conversion must route each new recursive call through the stack. A merge that compiles can still bring native recursion back.
