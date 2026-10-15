## 2026-09-21 23:01 CEST — queue row 58: the reserved output names begin with `_`

**What I did**

Spec first, red tests second, code third — and the order paid, because writing
§2 is what turned "rename `main.mjs`" into two rules with a guarantee over them.

- **`backend.md` §2** gained *The output tree does not depend on the file
  system's case sensitivity*: the guarantee is **a build's output is the same
  set of files on every file system**. Rule 1 — every reserved output name
  begins with `_` (`_main.mjs`, `_core/`, `_platform/`), which no module path
  can reach because every segment is an upper identifier. Rule 2 —
  `output_path_collision`, two written paths equal under ASCII case folding,
  checked over everything produced before the first byte is written. §5, §9 and
  §10's mentions of the old names moved with them; no section was renumbered.
- **`boundary.md` §5/§5.2** gained the `"entry"` manifest key, which finishes
  §5.2's own "declares … rather than hardcoding" for the one part of the output
  shape the emitter still owned — constrained by rule 1 and checked when the
  platform loads, `invalid_entry_file` otherwise.
- **`language.md` §10** gained both codes at the end of the catalogue. Its
  positional row labels ("the second-from-last line", …) were already drifting
  before I added two more, so they are now correct as well as stable.
- Red first, and the corpus fixtures with `_expected.diag` of `[]` so the
  failure was "the build exited 0", not a missing golden. With the behaviour
  reversed and the two new enum members kept, **36 of 280 fail**; with it
  applied, 279/280. The one is queue row 59, below.
- The `emit/` and `emit/release/` goldens were re-blessed and the diff **is
  paths only** — proved rather than eyeballed: rewrite `./_core/` → `./core/`
  and `./_platform/` → `./platform/` on the added side, sort both sides, diff,
  empty.

**What I learned**

- **The fixture the rule is really for cannot exist.** Rule 2's headline case is
  two modules `Json.Decode` and `JSON.Decode`, and a corpus fixture for it needs
  two source files that are themselves one file on macOS — the repository would
  not survive a checkout there. So the collision is provoked instead by a
  platform whose sibling and whose runtime land on the same output name
  (`platform/Prog.js` and `platform/js/PROG.js`, two source paths differing by
  more than case), and the real backstop is a harness invariant: after **every**
  build the black-box suite makes, fold the written-file list and fail on a
  duplicate. That one would have caught row 58 on Linux, where the file system
  hides it, and it costs one directory listing per case. It is the test I would
  keep if I could keep only one.
- **A defect is invisible exactly where it bites.** On APFS the two colliding
  files have already collapsed into one, so `listFiles` sees nothing wrong and
  only the emitted program misbehaves; on Linux both are there and nothing
  misbehaves. Neither side can see the whole thing, which is why this survived
  every green run until someone built on a Mac.
- **Moving a name into a manifest is not the same as making it safe.** The
  obvious fix — let the platform declare the entry file — would have let a
  platform author write `"entry": "main.mjs"` and reintroduce the defect in
  data. The key was only worth adding once the rule was enforced on it, which is
  the owner's decision restated: the guarantee, not the convention.
- The `abuse_test` 60 s timeout is **not** a compiler problem. Five warm runs of
  `check --jobs=1` over 5 000 empty modules: 12.05, 24.29, 26.11, 59.16, 61.16 s
  — while the default-jobs run beside it is 6.00, 6.00, 6.08. Identical,
  deterministic work, and USER cpu varies 6.77–16.22 s, which is a single thread
  landing on an efficiency core rather than a performance one. A wall-clock
  deadline cannot separate that from a hang on this hardware. Recorded as row
  59; the timeout was not touched, because the instruction was a number first.
  Frequency, since a flake needs one: `test-blackbox` was green on **3 of 4**
  consecutive full runs of the finished branch, red on the fourth, always this
  one case.
- A second thing fell out of measuring: `CLAUDE.md`'s `--release` figures are
  stale by ~1.9 kB against today's binary (row 60). The −31% claim is fine; the
  absolutes were recorded at an earlier commit. Left alone deliberately — the
  fix is one re-measurement of that whole paragraph, not patching the two
  numbers I happened to check.
- **Not run on Linux.** Everything here is darwin. The three gates are owed on
  the owner's NixOS machine, and the harness invariant is the part most likely
  to have something to say there.
