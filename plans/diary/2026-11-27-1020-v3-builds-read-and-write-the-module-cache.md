## 2026-11-27 10:20 CET — v3: builds read and write the module cache

**What I did**

- Worker `own3-speed`, issue #2549, branch `own3-speed-2549` on `ownership-v2-design-review` (base
  e22c75218e). Before, `Session.init` set the cache to null under `--ownership=v3`, so each build
  checked and walked every module, core's too: 17 of 17 modules for a program of two.
- Kernel §7.1 (new) says what a run under v3 keeps between builds, in four rules: the key is the
  transitive one; the key names the run (checker, enforcement, `--library`, the chain's markup
  settings); the entry holds v3's block, with no id of a session; a module with a line that stops a
  build is never stored. `fast-compiler.md` §8 points to it.
- Code: `src/own3/Block.zig` (the block: a module's `Contract.Published`, its lowering channel and its
  hoisted reads; a field as its name and a type as package, module and name; written field by field
  by reflection, so a new field of a contract is written with no change, and a field wide enough for
  an id of a session does not compile until `local` names it); `Enforce.keepBlock` and
  `Enforce.restore`; `Check.Cutoff.transitive` and the v3 term of `Key.Options`; the `ownership`
  section of the cache entry carries the block. A safe build reads back each block that it writes and
  compares it with the walk's, in every run, with or without a cache.
- Tests: `tests/blackbox/own3_cache_test.zig`, 9 scenarios, each compares a run with the cache against
  `--no-cache` (exit code, diagnostics, every byte of the output tree). Four mutations of the fix each
  fail exactly one scenario: the cutoff key in place of the transitive one (a contract-only edit),
  storing a module whose walk made a diagnostic (a refusal that a type error hid), a field's rank as
  a number and a type's id as a number (a block read in a session with other ranks and ids).
- `bench/ownership-v3-cache.mjs`: over the 2 586 ownership roots, `check` with `--no-cache`, then two
  times with one cache directory that all roots share: 0 faults; 49 079 modules installed; each of
  the 1 939 roots that check clean has no miss in its second run.
- Evidence that no verdict moved: dumps of the 2 586 roots, base against the change: no byte differs.
  Ledger: v3 accepts 309 of 319, as before.
- Time, ReleaseFast LLVM, runs alternated, under heavy-run's CPU limit, `examples/conduit` (17
  modules, 3 560 lines) with `--ownership=v3`: least of 25 rounds, base 253 ms for each build; with
  the change 57 ms warm, 136 ms after an edit of `Main`, 167 ms after an edit of `Api`, 298 ms cold
  (270 on the base). Instructions (callgrind, `--jobs=1`): no cache +0.015 %, cold +2.2 %, warm
  −94.9 %. The program of two modules: 47 ms before, 13 ms warm.

**What I learned**

- A pair of bodies with one type can still have two interface hashes: `xs` and `List.copy xs` share
  one, `List.map` and `List.push` have another (a fact of the body is in the record). My first
  contract-only edit moved the interface hash, so the cutoff key saw it and the mutation was not
  caught. The scenario now asserts that the hash is the same before and after the edit.
- A label's `head` is a `TypeId` only for a constructor's argument, an opaque type's slot, and a
  member that is a list, an opaque value or a cell (`own2/Groups.zig`, `Adapter.describeOr`): every
  other head is 0. A stale id did not accept a write in my cases: the importer found no location for
  the label, read the answer as every cell of the argument, and refused. The scenario that catches
  it needs a write that is accepted only with the exact location, and a later read of another one.
- v3 reads the BIR of other modules at about fifteen places (`m.in.birs[t[0]]`), so the cutoff key
  cannot serve it without a closed list of those reads. That list is the work that a contract cutoff
  needs; it is not in this change.
- `zig build` loads every source file in the first seconds of a compile. A base compiler whose
  compile started before my first edit is a true base; I checked the process start time against the
  file times before I trusted it.
