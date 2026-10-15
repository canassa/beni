## 2026-09-26 — R7: own methods without a scheme, merged groups, order independence

**What I did**

- Priority groups and `method_needs_annotation` for ordering are gone from v2. A use of an
  unchecked own group checks it at once in a fresh frame (`Groups.zig`, nesting at demand, with a
  cumulative budget; `nest_cost` = 3, measured at about 15 KB of stack per Debug nesting of a
  reverse-ordered chain, so ~600 deep); a back-edge merges top-level frames, which hand their
  pools, binders and queues to one root and generalise once; every frame has its own ready queue.
  D14 lowers group-level receivers in recursive groups, and its hint is computed at the class
  root from the source only. Queue row 75, where this rewrite began, is closed here (CK-36).
- The contract is I9. `scenario/PERM` checks 48 programs over 2 796 declaration orders; the
  reviewers' fuzzers ran ~63 000 more orders with no difference in acceptance or output.
- Three review rounds. The adversarial fuzz found order dependence the implementer's own scenario
  missed: `x.combine 1` became a field call or a method constraint depending on which fact
  arrived first (also in plain value recursion), and the D14 hint named different members by
  order. The structural review found a merge during the root's boundary losing members; round 2
  found a joined dot-call/`where` requirement inheriting a field answer (internal error).
- Owner decisions (2026-09-26, all yes): a dot-call whose receiver becomes a record before the
  constraint is generalised is a field call (spike §11 *Deferred receiver*); I9 promises
  acceptance, types and output, not the exact error set of a refused recursive group; and at
  R14 a `let` whose requirements are only dot-calls stays monomorphic.
- New CK-105 (field call vs method by order) and CK-106 (a `number` receiver's method in a
  recursive group was `internal`, also in v1). 99 claims. Bench 1.08–1.09× v1, little headroom.

**What I learned**

- A permutation scenario written by the implementer proves the cases the implementer thought
  of. A random generator with every order of every program found the field-call hole in minutes.
- Some order dependence lives in the language rule, not the code: the old spec text itself
  decided by "already known". Fixing I9 needed a language decision from the owner.
