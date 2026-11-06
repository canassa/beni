## 2026-11-06 08:26 CET — Fix the gate failures that workers-hostfree inherits

**What I did**

Worker `schema-dual-path`, after Jayson's "fix 1971's gha tests". I opened the branch
`workers-hostfree-gate-fixes` from `workers-hostfree` `f631a01f02` for the base's 20 failing
corpus cases, the `ownership` golden and the playground case, so that #1971 can stack on it.

- #2114: I regenerated `tests/corpus/ownership/core.v2.unchecked` with the corpus walker's own
  bless switch, limited to that file. The diff holds only #1965's four changes.
- #2090: the named wasm compiler (`zig-out/wasm/bin/beni.wasm`, self-hosted, with a name
  section) showed the overflow in `check.constrain.Expr.expr` → `check.constrain.Expr.call`,
  one pair per operand of the 4 095-term chain. With a 2 MB V8 stack every other pass got
  through, so only `constrain` needed a change. `call` now begins a first argument that is a
  call on a list of open calls. A new gate test in `wasm_test.zig` fails on the old `constrain`
  and passes now; `zig build test-playground` passes.
- #1848 B: the four `build/bad/inline/` goldens fail because the typed dispatch queue gives
  each command body to `Js.Dispatch.send`, whose callback is `sync`. The checker's sync check
  then refuses the body before the inline lowering can give `browser-inline.md` §5's class-2
  `not_implemented`. No mechanism lets a platform mark a sync position as a compiler limit, so
  I asked the owner (`schema-dual-path-q4`).
- #1848 D: I wrote the actual output of the 16 failing `emit/` goldens into a scratch base
  worktree and audited each diff, as #2113 did. 5 have only fixed or deliberate causes, and I
  blessed them one by one. 11 have #1859's causes; I asked the owner (`schema-dual-path-q5`).

**What I learned**

- A Zig wasm build with the self-hosted backend keeps function names, so a V8 `RangeError`
  stack names the recursive function. `node --stack-trace-limit=40` shows enough frames, and
  `--stack-size=<KB>` sweeps show which passes need more than the default stack.
- `checker-v2.md` §10.2 rejects a general continuation stack for `constrain`, `solve` and
  `resolve`. A narrow one for the first-argument spine is enough for an operator chain: the
  solver's recursion over the same `and_` tree fits V8's stack at `Parse.max_depth`.
- Counting signatures (`$opt`, folded `isInteger(512)`, option thunks, defect arms) in the old
  and new golden is a quick way to sort a golden's diff by cause before reading it.
- A bless run with `BENI_BLESS_ONLY` in a scratch worktree gives every actual output at once,
  without touching the branch.
