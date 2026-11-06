## 2026-11-06 17:33 CET — solve the relation to its fixed point

**What I did**

- #2146: `Distinct.overlap` answered `no` for a pair in progress and kept every pair it
  finished, those computed under that cut too, so a later read took a partial `no` as final.
  A plain `List.foldl` wrote in place under a live reader, and swapping the tuple fields
  read flipped the verdict.
- `src/own2/Pairs.zig` solves the relation: one depth-first walk that finds the equations'
  strongly connected components, a component's head walking it again until no value moves.
  A row enters `solved` when its component is solved and never before, and `solved` goes when
  a key grows. `ov_memo` is gone. Spec: `ownership-v2.md` §2.9.2, *The fixed point of the pairs*.
- Audited every walk in `src/own2/` with a cut, a mark or a visited set. The class audit is in
  the PR. The two cuts #2146 named with no `min_cut`, `instBelow` and `expandRouted`, are never
  reached: 0 of 58,823 programs. Each now panics under runtime safety if one ever is.

**What I learned**

- The owner's order was to try deleting the memo first, and the measurement decided it. With no
  rows the walk is exponential (a chain of diamonds passes its account at n = 20). With rows per
  query it is n²: `y_k = pick c y_(k-1) (List.push z k)` went from 119 501 to 760 296 at n = 800,
  and `the checker v2's call costs are flat` failed. That test is why the solved table stays for
  the evaluation. It is the question to put to the owner.
- A generator's `SAME` on master is no evidence of safety. All 34 SAME→REFUSED were a branch their
  input never took; with another input and iteration count, master traps on every one.
- My first class check counted unfinished programs as accepted and showed two false splits. Read
  a partial file as partial.
- `zig build test-run-hashes` in `CLAUDE.md` no longer exists: the gates cache digests themselves.
