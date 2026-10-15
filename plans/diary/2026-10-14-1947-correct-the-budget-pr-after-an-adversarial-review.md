## 2026-10-14 19:47 CEST — correct the budget PR after an adversarial review

**What I did**

Reran the CPU sweep with the compiler rebuilt for each model, because
`BENI_EXE` ignores `--prefix` and the first sweep had changed only the
harness. Scoped the budget text in `CLAUDE.md`, `build.zig` and the corpus
README to the one host measured, and named what still follows the host and
the `-Dllvm` gate's other count. Made `gates` refuse hybrid Intel hosts,
gave the refusal tests a guard against nested gates, and stated what a session
that cannot count does before it opens a PR.

**What I learned**

`installPath` writes `BENI_EXE` under the build root whatever `--prefix`
says, so a prefixed build runs the tests against the last unprefixed compiler.
Built for a baseline CPU, compiler and harness put 9 `browser/direct` cases
over the budget; `x86_64_v3` without SHA puts 7.
