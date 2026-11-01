## 2026-11-01 17:16 CET — own2: fold-first propagate, built

**What I did**

- Built §2.9 *Fold first* (#1543) in a new `src/own2/Propagate.zig` (L5), bound into
  `Cond.Table`; the depth-first walk is gone. Pass 1 reads the state graph and stops at
  clean-memo hits; pass 2 takes components and cycle bits, with resumed passes over new
  states only and a reopening of any component that changed; pass 3 builds positions by
  their set of states, exact folds as closures. The reference walk and the
  `runtime_safety` cross-check (rule against reference and against itself without memo,
  both frontier orders) are in the same file.
- Added the hidden `--ownership-propagate` dump and four test-only mutations
  (`-Downership-v2-mutation=propagate-…`). Each counted test fails under the mutation it
  pins.
- Counted fixtures in `Cond.zig` (shared DAG, sibling, self-loop, coprime knots, resumed
  hit, two-leaf merge) and black-box tests in `build_test.zig` (#1289's chain, a doubling
  record, the dump line). Four §4.1 tests used the doubling record as their "genuine
  product"; it costs 2 670 records now, so they use the doubling calls `w_k`.
- Rebased onto #1535, #1540 and #1538 when they merged, and carried #1538's atom rule
  into the rule's link test.

**What I learned**

- The rule gives the walk's id in every one of the corpus's 30 533 calls, measured by a
  scratch build that ran both. The only visible changes are fresh-label numbering in four
  roots, from `proj`'s order.
- After #1538, #1289's chain is linear under the old walk too. The doubling record
  (`{ l = s, r = s }`, 11 levels) and the sibling fixture are the witnesses that fail
  without fold first.
- `-Downership-full-cross-check` makes v1's own §16.7 check panic on 15 fixtures. That
  is v1 and was there before; v2 has to be compared with `--ownership=v2` dumps there.
- `removeMin` stays a limit at 10⁸ (#1372). The rule's largest joins read about 29 000
  states and 680 000 edges. The old walk's peak memory on it was 3.6 GB, the rule's 450 MB.
- A recast's own child is a whole recast of its inner, so under an exact fold's cursor
  it reaches everything the inner reaches. A fixture that wants a state reached only
  through a hit must share the set through two recasts' inners, not a recast and its own
  child.
