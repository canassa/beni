## 2026-10-16 03:41 CEST — copy in RefModify's callback

**What I did.** Issue #219, the owner's decision: `run/RefModify`'s `Ref.update`
callback pushes onto `List.copy ns`, so the program holds no line under
`--ownership-everywhere`, and `check/bad/direct/RefUpdateShared` keeps the
refused form beside a `snapshot` read with `Ref.get`, which is the sharing the
error names. `ownership-checker.md` §30.9 carries a dated amendment. `Ref`'s API
and words are unchanged. Recording run hashes also re-recorded one
`build_test` scenario (`--library --release` keeps `core/Schema` exports) whose
hash master had left stale.

**What I learned.** A `Ref` is not a checker limit: any holder may keep what
`get` read, across fibers, so the borrowed row on `update`'s callback is the
sound one, and the copy belongs in the program.
