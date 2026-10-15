## 2026-09-29 01:34 CEST — The checker rewrite is finished; the tests take ten seconds

**What I did**

- Closed the checker rewrite: the audit's last open finding (interfaces now name aliases and
  write each body once per record, bytes linear in a chain's length), the structural clean-ups
  (dead guards and the unused undo journal deleted, a growing stack, invariant checks proven
  live, a caller-independent unify contract), and two final read-only reviews and their fixes
  (alias names agree-or-expand at every depth, the exponential alias DAG, truthful field and
  equality messages, the schema endpoint keeping its name, a safety-build quadratic, and output
  paths that are symlinks refused). tests/pending/ is empty; nothing unsound, crashing or
  order-dependent is known.
- Rebuilt the test system around speed: a self-hosted ReleaseSafe beni by default (LLVM behind
  -Dllvm), sweeps and matrices replaced by hand-picked tests, a 4 300M-instruction budget per
  test, Node skipped for verified output (0 runs on an unchanged tree), sharded processes,
  instruction-based timing scenarios, test-time reporting and block-guard coverage written in
  Zig. The gates went from about 5 minutes to about 6 s warm and 10 s after an edit; the
  testing tiers were deleted as obsolete.
- Found and fixed real defects on the way: a cache reader and every file read trapping when a
  file changes under it (a Zig 0.16 std issue; draft upstream report in plans/), a stale-binary
  false green from sharing one Zig cache across worktrees (reverted).
- The owner took the browser direction: The Elm Architecture with Solid 2's compiled JSX, Solid
  2's render loop and JSX answers, TEA possibly as a platform. Research 36 studied Solid's Rust
  JSX compiler for the port.

**What I learned**

- Every review round found something until the last; the ones that mattered came from
  differential oracles (two orders, two job counts, warm vs cold, dev vs release, two backends).
- Several "tests" asserted nothing for a long time (the acceptance matrix's dumps, most of the
  identity oracle); sweeps hide that, hand-picked tests reaching named branches do not.
- A tool that shares state across worktrees must be proven safe on this Zig version first.
