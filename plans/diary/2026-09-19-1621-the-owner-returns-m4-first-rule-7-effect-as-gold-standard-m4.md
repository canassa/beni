## 2026-09-19 16:21 CEST — the owner returns: M4 first, rule 7, Effect as gold standard; M4-1 lands

**What I did** (manager; Opus agents implement; I validate, land, push)

- **Owner decisions taken today**: M4 before effects; `lazy` parked until a
  browser platform and a large app want it (M3d shrinks to static multi-entry
  chunking + the single-file release bundle); `--release` refuses `Debug`;
  `Int32` is built; effects gets a full spike with **Effect-TS v4 as the gold
  standard** ("Effect-level quality and API coverage"); and the stance that is
  now `CLAUDE.md` **rule 7, guarantees not restrictions**.
- **M4-1, the persistent cache** (`1191d46`..`008e5e1`, spec `36dc8df`): a
  module whose key held is not re-checked. Warm `check` 63 ms against 131
  (`--jobs=1`, 100k lines), within the spec's prediction; the front end is 76 %
  of a warm run, which is M4-2's. An import contributes its KEY, not its
  interface hash, so a comment in a leaf still re-checks importers until M4-3.
  Warm ≠ cold was never observed; I truncated every entry by hand — 14 misses,
  then 14 hits, output identical to `--no-cache`.
- **`core/Int32`** (`dca83e9`, `d6582ba`): my own FNV-1a in beni printed the
  published vector under `--release`. It also exposed that any function named
  `add`/`eq`/`cons` in any module was reported as "the (+) operator".
- **`--release` refuses `Debug`** (`ad1144b`) with a hidden `--allow-debug` so
  the 24 `Debug.log`-based order fixtures still run in the release pass.
- **Robustness audit** (`1592b34`): 613/613 files idempotent under `fmt` with
  AST, comments and emitted JS preserved; 86 900 mutants, no crash. What broke
  was the CLI around them — `beni check .` rejected every file, `fmt` reset
  modes to 0644 and replaced symlinks, `dump` exited 0 over an error — all
  fixed (`0bc5d89`..`492842e`).
- **Effects research**: `references/effect` vendored at 4.0.0-rc.116; reports
  21 (runtime, measured), 22 (API surface), 23 (78 executed semantics cases);
  `plans/effects-decisions.md` (16 / 11 / 9 decisions by tier, five to answer
  first) and `plans/effects-spike.md` (sixteen slices, kernel probe first).

**Corrections to things I told the owner**

- I said `Int32` had "no design paragraph" and recommended striking it. Wrong:
  `fast-compiler.md` §3.1 and `checker.md` Appendix B specify it; I had
  repeated an audit's summary without checking. The owner then explained it was
  an EXAMPLE of a stance, which became rule 7.
- My hand test of the cache "found" a body edit with zero misses. The file
  content had been written by an earlier failed attempt of mine and was already
  cached — content addressing doing its job. Check the test before the code.

**What I learned**

- **The owner's stance changes recommendations I had already made.** Under
  rule 7 the default for a restriction that buys no guarantee is a warning, and
  the default for a capability gap is to fill it inside the wall. Report 22
  applied it within the hour: a shipped program cannot log (queue 51).
- **Executable research beats read research.** Reports 21 and 23 installed the
  vendored version and RAN it: two of report 16's quoted figures failed to
  reproduce, v4 turned out not to be the runtime report 16 studied, and 51 of
  78 observable behaviours are simply absent from the proposal. A design
  document reviewed only by reading would not have shown any of that.
- **When a long slice must rebase over a busy master, send it back to its
  implementer.** I started M4-1's nine-commit rebase myself, hit a conflict
  that recurs per commit, and aborted; the implementer resolved it with context
  AND used the new base to strengthen four tests. The manager's rebase is for
  one-conflict cases.
- A test that leaves a read-only directory behind breaks `git worktree remove`
  — harmless, but the harness should restore modes on teardown.
