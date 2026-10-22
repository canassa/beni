## 2026-10-22 07:59 CEST — Log.setMinimum, the program's minimum

**What I did**

- Rebased #622 onto a `master` 44 commits ahead: master's side of the 25 server run hashes, then
  one locked job of test-run-hashes and the gates, and a lease push. Jayson merged it.
- Built `Log.setMinimum : Level → ⊤` (#551), as Cesar decided: a program-wide minimum, the last
  call wins. A log context's `minimum` is `undefined` until `Log.minimum` sets one, and a call then
  reads the program's cell. Fixtures `run/LogSetMinimum` and `browser/tea/LogSetMinimum`.
- Named `setMinimum` in the skill and in AGENTS.md, and fixed the skill's browser page, which
  still listed a browser `Log` module and had no `Cmd.log`.
- Measured bytes with one compiler and two `--core-root` directories, `master`'s `core/` and the
  branch's: only programs that reach `Log` change.

**What I learned**

- `--core-root` gives a byte comparison of a core-only change without a second compiler build:
  the same binary, two exported `core/` trees, every fixture built with both.
- The release optimiser folds a `Js.ref` that nothing writes to its first value. With
  `setMinimum` unreached, the program's minimum is the constant `Info`, and a release build that
  can also fold the log context pays nothing for the feature.
- A `skills/beni` page written by hand does not go stale in the gates. Only the generated
  `api-*.md` files do, so a PR that moves a module also reads the hand-written pages that name it.
