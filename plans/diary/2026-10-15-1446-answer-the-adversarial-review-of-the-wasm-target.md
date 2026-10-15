## 2026-10-15 14:46 CEST — answer the adversarial review of the wasm target

**What I did**

PR #133 (the WebAssembly target) was merged at 11:47 UTC, before the
adversarial review reached its verdict, so the review's findings on it are
on a branch of their own from `master`.

- `src/js/Spec.zig`'s points-to fixpoint kept its waiting set in `usize`
  words and walked it a word at a time, so wasm32 took more sweeps than
  x86-64 (99 against 89 on `browser/direct/KeySubscription`). The set is in
  64-bit words now; native counts did not move, and `test-playground`
  asserts the shipped `.wasm`'s count on six programs (red before, green
  after).
- A black-box test for the redirect defect of the first pull request:
  `{ echo first; beni version; } > file` lost the shell's line (red with the
  positional writers, green with the streaming ones).
- The printing-program `.wasm` test asserts the profile's
  `embedded_modules` and `modules_checked`: a refused pack changes no byte.
- Jayson decided H1 on the dashboard (`wasm-playground-q5`): the two `.wasm`
  gate tests have 6 000M of their own, counted on a meter of their own as a
  corpus case with a `.budget` file is, and `ci.yml` has a `playground` job
  that `check` needs. Cesar's agreement is pending.
- `test-playground` runs the page's own commands and the JSON renderer:
  786 programs, 2 118 commands.
- Smaller: a 64-bit bounds check in `type_body.zig`, the `-Dllvm` cost in
  CLAUDE.md, and the spec's sentences the review disputed.

**What I learned**

- An order that follows a `usize` word is a second way for wasm32 to differ
  from x86-64, beside threads. The bytes matched only because no program
  came near `max_pts_sweeps`; a count in the profile showed it, a byte
  comparison could not.
- `perf stat` of a whole test binary counts more than the budget does: the
  grant's meter counted 3 680M for the printing-program test where the whole
  binary counted 4 620M.

**Corrections to earlier entries**

- 12:50: "765 programs" was 765 at that commit; the corpus grows, and
  after the page commands this run is 786 programs and 2 118 commands.
- 13:25 (on the editor branch): "Three samples build for `browser-direct`"
  is wrong for the printing sample, which builds for `node`.
