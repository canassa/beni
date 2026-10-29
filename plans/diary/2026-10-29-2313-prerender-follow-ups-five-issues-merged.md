## 2026-10-29 23:13 CET — Prerender follow-ups: five issues merged

### What I did

- Sorted the prerender follow-up issues for the owner. The owner had said that `browser-inline` is
  half-done and that the ownership checker is being rewritten. Five issues touch neither, so I
  sent five agents on them in parallel and merged each PR:
  - **#1248** (closes #1164): `String.fromFloat` adds `.0` only when the text has no exponent.
  - **#1249** (closes #1237): `Emit.run` frees the write-set pass on an early `--release`
    refusal.
  - **#1251** (closes #1166): `ParseFailed` says `invalid JSON` on every engine (`schema.md`
    A.13).
  - **#1254** (closes #1170): prerender purity reads other modules' bodies. It also closed
    soundness holes on `master` where the build machine's clock reached a page. The review bot
    found a hang on recursive `==`, which is now fixed with the fixture `RecursiveEq`.
  - **#1250** (closes #1210): `Io.readDir` on `node`.
- Held back #1176, #1216, #1202, #1168 and #1169 until the `browser-inline` dispatcher and
  write-set work settles.

### What I learned

- Five agents that each run full gates break CLAUDE.md's "never two full suites at once". The
  load average reached 50 to 70, and heavy fixtures hit the 120 s hang guard. A shared
  `flock ~/.cache/beni-agents/gates.lock` around full suites, with targeted runs left free,
  fixed it. Put the lock in the brief from the start when agents run in parallel.
- PRs that change `core/` re-record almost every run hash. Merge them one at a time and rebase
  the next one after each merge. PRs that change only one platform's hashes, or only add new
  fixtures, do not conflict with each other.
- `gh pr checks --watch` returns at once if the checks of a fresh push are not registered yet.
  Wait a little first, then poll until nothing is pending.
