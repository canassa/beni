## 2026-10-16 15:04 CEST — only an inert holder goes after the rewrite

**What I did.** The second review of PR #183 (issue #95) found that a key or a top-level binding
whose value is a field read (`{ step = ops.fn }`, `picked = ops.fn`) still made the used-once rule
write the body at the call while the lambda stayed: raw 434 → 450 and 438 → 450. `dropKeys` and the
top-level sweep drop only an inert value, and `ops.fn` is not inert. The review proposed a fix that
asks for an inert key value and an inert top-level initialiser. I checked it with more programs, and
four more grew by 16 raw bytes with it: a local `f = ops.fn` read by a key `{ step = f }`. An
instrumented compiler showed the cause: slice 9's rule `const x = e; return R` writes `ops.fn` in
place of `f` when the `return` reads `f` once and first, in the same pass, after slice 8. So now
every holder must be inert, local bindings too. Five `Tea.document` pages give up 39–57 raw bytes
against the PR and stay smaller than master: there `update = app.update` was a local holder that
went only because `init` is read first. Three new `emit/release/app/` fixtures are red against the
PR, and `SpecRecordLambdaLocal` also against the proposed fix. I rebased on master (no `src/`
change), re-recorded six run hashes and measured again under the shared lock and the memory cap.

**What I learned.**

- A proposed fix is a hypothesis. Three programs passed with it; the fourth shape, a plain
  local binding of a parameter's field, did not. Vary the shape (local, top-level, parameter,
  call result, `case` branch) before accepting a rule about "what goes".
- A rule that predicts what later passes do must count only what every later pass keeps. Slice 9
  runs after slice 8 in the same pass and can turn an inert key into a field read.
- A win that depends on key order (`init` before `update`) is luck, not a rule. Name it in the
  design text and give it up, and open an issue for the rule that gets it back safely.
- `beni` has no dump of the specialised IR. A scratch copy with `std.debug.print` in `dropKeys`,
  at the phases of `Spec.run` and around each pass found the pass in four builds. Build it with
  `--prefix` and `--cache-dir` in scratch, never in the worktree's `zig-out`.
