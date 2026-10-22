## 2026-10-22 08:03 CEST — Rebase PR #631 and check master's lowering inputs

**What I did**

Rebased `emit-cache-read` (`2b64f8472`) onto master `13d463f8f` (66 commits).
No conflict. The branch is 10 commits; the read path is unchanged.

Read the seven master commits that change lowering and answered one question
for each: does it add an input that reaches the bytes of a core unit that a
development build takes from an emit row, and does `planReuse` check it? Only
`3474fbd5c` (omit unwritten unit arguments across modules) reaches the bytes.
It reads the imported callee's declaration patterns (`Lower.unwrittenArgs`,
`src/js/Lower.zig:3794`), which are canonical module-graph data: the maker
passes the same BIR and provenance (`src/core_pack_main.zig:390`), a unit's
`Needed` entry pins the callee's module and value slot, and the pack is
rebuilt with the compiler. No fact is needed. The other six commits are
release-only (Spec, field names, case chains), and a release build reads no
row (`src/js/Emit.zig:4848`). No code change.

`zig build test-run-hashes` recorded 2507 hashes. The only change is
`tests/corpus/run/SchemaShapeThreshold.run-hash`: `release` and
`release_library`, because master's release changes alter its release
JavaScript; the program still prints 210 and the development hashes did not
move. `zig build gates` passed on the rebased tree. Pushed with
`--force-with-lease`.

**What I learned**

A `failed command:` line in the gates log is not a failure. The build runner
prints it for any step that wrote to stderr, passing or not
(`tests/blackbox/docs_test.zig` says so); the exit code decides. For the row
tests, separate **build state** (facts the maker must ask) from **canonical
module-graph data** (the same in the maker and the build): only the first needs
a `planReuse` fact.
