## 2026-10-30 20:45 CET — own2: write demands per path of the pair graph, several on one argument in growth (#1358, #1356)

**What I did.** Two causes, two commits.

- **#1358.** `Demands.resolve` put every demand on the lane
  `(base instruction, direct_demand_query)`. All of one call's writes on one
  argument share that instruction, and each charges two records on the lane
  (its cell, and the escape check at its root cell), so 256 written fields
  filled the 512 records and 257 stopped on `ownership_accounting_invariant`.
  #1352's other-paths fix did not touch this. Several demands on one base are
  now growth, from a sort of `(base, index)` words before the work (§4.1's
  *direct demand query* row says so). `caller w = wall w`: 320 fields 26 527
  records, 640 fields 54 629, about 85 a field.
- **#1356.** `Calls.marked` listed every path of a use shape to a `W`, and the
  caller made one demand per path. `Calls.Routes` now walks the use with the
  argument's value: sibling steps that reach one `(use node, value node)` pair
  are one route from there, so one demand, named by the route met first.
  Their base, their other paths (`otherPaths` walks the same pairs) and their
  marks are the same, so the verdict and exactness are the same; the cause is
  the witness's. Escapes go the same way. `Transfer.call` reads the routes one
  by one, and a value is projected when its route is popped, so nodes and
  cells are made in the order the per-path reading made them. Spec:
  §2.11 item 3, *One demand per path of the pair graph*.

Derived comparison over `w4`: 56 633 → 1 111 records; `w8` (128 levels):
`ownership_summary_size` → 13 111. Direct writes over `x_k = ( x_{k-1},
x_{k-1} )`: depth 4 1 421 → 289, depth 8 38 486 → 534.

v2 dumps of 827 ownership/, ownership/core/ and run/ cases, master against the
branch: one difference. `CallOtherPathsKeys.shared` puts one list at `x` and
`z`; the two refused demands are now one (at `.z`), entered in
`ownership-v2-known.txt` as `rejected :: absent`.

**What I learned.**

- Use shapes are interned, and places are per type, so `wall`'s 320 written
  fields are 320 entries to ONE leaf node. "Shared use node" alone would have
  merged almost every call that writes two fields of one type. The merge has
  to be by the pair with the value, and then only values that are really one
  object merge.
- A parameter's positions are distinct cells per path, so a doubling DAG type
  over a parameter (`t_k ( a, b ) = t_{k-1} a + t_{k-1} b`) is still
  exponential in the callee's own frame and in a caller that passes its own
  parameter. Only shared values got linear.
- Found on master: `w2 x = w1 (w1 x)` has `res .1 = .0` and loses `π1`, so
  `case w2 xs of ( ( a, _ ), _ ) → touch a + List.length xs` is accepted
  `fresh` (v1 refuses). Filed #1364.
- Slow: one source line of 640 terms costs 579 ms in `dump --stage=tokens`
  (12 ms on 640 lines), quadratic in the line's length; filed #1365. The
  counted tests put one term on a line. 640 written fields still take about
  0.9 s to check, so the two sizes are two tests with a per-field bound.
