## 2026-10-20 11:19 CEST — the second rebase, the lift ask and the wasm's growth

**What I did**

Jayson's decision on #438: one more commit before the merge. Three things, then
a rebase he asked to check.

- **The reviewer's Medium — the export list's lift read.** `Lower.zig`'s piece
  exports loop read `r.of(l.in.module).lift(gi)` directly, while the only two
  `.lift` asks sat at `livePiece` and `liftPieces`. The join rebuilds the tail,
  so the answer is derivable — but the spec's completeness argument is by way
  of the accessor, and every read of a unit-reachable fact asks. The loop now
  asks exactly like the other two sites (commit `8f7ecb827`). The ask lands
  before the first unit, so it belongs to no unit; the maker encodes only a
  unit's own facts, so no row and no pack byte moves.
- **The reviewer's wasm Low.** The playground's wasm embeds the same pack, so
  it grows too. The PR body and `backend.md` §9's slice-2 note now say it with
  the reviewer's two-pack proxy: brotli q11 883 409 → 1 260 000 B
  (+376 591 B).
- **The rebase.** `git merge-tree` conflicted: `origin/master` had moved 76
  commits past `acccea6a3`, including deleting `platforms/browser-direct` and
  `22ba02cb9`, which removed `Sites.runner` and returns `readValid` at a run's
  callee. Rebased onto `697b77fc6`; one conflict, in `src/js/Lower.zig`:
  master's `readValid` and its assert stayed, and the slice's `.schema_library`
  ask was re-expressed through them. Seven commits, clean tree.
- **Re-proof on the new base** (`reb2-job.sh`, under the lock): a
  master-against-branch `diff -r` of the three trees is empty — 16, 43 and 62
  files byte for byte, source maps included, tree-sha256 equal — and
  `zig build gates` is green (the docs_test step's `failed command` line is
  the documented stderr artifact, and the same line is in yesterday's green
  run). No program ran under Node for want of a run hash.
- **The figures moved with the base**, as they had to: deleting a platform
  deletes its modules and the `direct` chain, and the rebuild changes the
  pack's payloads. Re-measured: the pack grows from 3 486 231 to 5 570 755
  bytes (+2 084 524), the 116 emit rows are 58 keys — 55 modules plus three
  extra chain instances, all `Html` (its own chain, `ssr`, `dom` and `inline`,
  with `browser` and `browser-tea`'s `dom` one) — holding 51 payloads of
  2 081 276 bytes plus 3 248 of row table (was 4 182 851 → 6 672 561, 128 rows
  / 64 keys, 53 payloads, 2 486 126 + 3 584). The five unit-less modules are
  unchanged (`Js`, `Record`, `Url/Parser/Internal`, node's `Ssr` and
  `browser-inline`'s `Tea`). `Dom`, `Hosted` and `Browser.Events` are no
  longer keyed twice: the second key was `direct`'s. The note and the PR body
  carry the new figures and the new per-module sentences; an instrumented
  maker (one print in `moduleRow`, built and reverted) printed the 58 rows.

**What I learned**

- A rebase is not only a byte-identity question: every *measurement* a PR
  states is relative to its base. Master's platform deletion moved the pack's
  row count, its keys, its payloads and the per-module sentences, so the
  As-built note had to be re-measured, not just re-diffed.
- The build runner prints `failed command` for a step that *succeeded* when
  the step writes to stderr; the repo documents it at `corpus_test.zig:447`
  and `build.zig:562`, and yesterday's green gates log has the same shape.
  The exit code is the verdict, not the last line of the log.
- `git rebase --continue` opens an editor even after a conflict resolution;
  in a non-interactive shell it waits on vi forever. `GIT_EDITOR=true` is the
  fix, and the rebase state survives the kill.
- Master's `readValid` change (workers called at their use sites) left the
  slice's `.schema_library` ask at `referenceName` correct for a different
  reason: the branch is reached only by the library's form of a direct run,
  so the unit still carries the answer even though the returned name is now a
  constant.
- The platform deletion is legible in the row data: `Html` went from five
  keys to four, `Dom`, `Hosted` and `Browser.Events` from two to one, and
  `browser-direct` took its own two modules (`Direct.beni`, `Tea.beni`) with
  it — 57 modules became 55, seven extra chain instances became three, and the
  128 rows and 64 keys became 116 and 58.
