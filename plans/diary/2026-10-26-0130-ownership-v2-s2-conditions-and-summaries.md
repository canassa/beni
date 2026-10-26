## 2026-10-26 01:30 CET — Ownership v2 S2: conditions and summaries

**What I did.** Built slice S2 of `docs/design/ownership-v2.md` §8 on S1's
tables (#1013), as two stacked pull requests: `Cond` and `Summary` (#1036),
then `Liveness` and `Rows` with the `mark` origin, `Supply.cond` and
`Shape.withCells` as the L2/L3 extensions they need. `Cond` owns the κ
column and both conjunctions — the O(1) binary `and` a store forms and the
canonical flat form a fixpoint joins through, one id per atom set — plus
`sep`, `apart` (ListOfParams is one atom, O(n)), `deep`, `lower`,
`propagate` (κ of a `Shape.join` from its members, O15), `instantiate`
and `rely`. `Summary` is the class record, the pointwise lattice, use
shapes as shape nodes over mark cells, the normal form as words and v1's
print grammar. `Liveness` sorts a frame's uses by `(local, path, point)`
with paths in lexicographic step order (a subtree is one index range), a
merge-sort tree for the point-interval query and binary lifting over the
region tree. `Rows.fromWords` reads today's words into classes, with
constructor and derived-method classes beside it. Every record is reserved
on the caller's `Charge` before it exists; the gates and the own2 unit
tests are green, §5's `Summary` target was raised to 1 400 with the reason.

**What I learned.**

- A "parallel column of labels" keyed by `NodeId` cannot label a use shape:
  nodes are interned structurally, so two parameters with one use structure
  share a node. The labels have to be the node's cells, hence the `mark`
  origin, carried down a leaf by `proj` as `⊤` is — which also gives §2.7's
  lazy call-use query for free as one `cellsAt`.
- `sep`/`apart` atoms over arrivals must mean DEEP separation, or a symbolic
  leaf's lazily projected children could not default to κ `yes`:
  `[ π₁, π₂ ]` at `[*].a` is exclusive only if the two arguments share no
  object anywhere. `Calls` must discharge the atom by reach-disjointness.
- `fresh` without `exclusive` is best modelled as a `recast` of the fresh
  leaf: the call made the object, but the same inner object may sit at any
  path, which is exactly a recast's "inner's cells, approximate, at every
  path" with κ `lost`.
- A perl `-0pi` substitution with `|` delimiters and `\|\|` inside the
  pattern corrupted a file header twice; for multi-line edits use the Edit
  tool after a Read, never a shell one-liner.
- The lexicographic order of canonical paths by their steps makes every
  descendant contiguous after its ancestor, so a path-trie DFS interval
  needs no separate numbering pass: two binary searches give the subtree.
