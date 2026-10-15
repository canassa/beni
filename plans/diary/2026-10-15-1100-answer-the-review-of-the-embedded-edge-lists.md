## 2026-10-15 11:00 CEST — answer the review of the embedded edge lists

**What I did**

Answered the adversarial review of PRs #118 and #122. The rebase onto the
diary split closed its first finding: my earlier hand merge of
`plans/diary.md` had read master's stray `|||||||` line as the start of a
conflict's base section and dropped four of master's entries. In #122:
`EdgePack.zig`'s header and `fast-compiler.md` §8 now name all four kinds
of edge a row can drop and the condition the drop needs (the maker's
graph holds every module a build's graph can hold, because
`Session.isLazy` is false when a run makes a pack); `EdgePack.decode`
refuses a row whose start lists, their order or its chains do not fit;
the differential tests also build with `--jobs=1`, and two more compare a
`--release` `browser-tea` page and a `browser-direct` page. Corrected
both PR bodies: the gates' determinism test runs no `build`, so the
evidence for rule 5 is the review's 1 984 builds at two `--jobs` values
and the new `--jobs=1` builds.

**What I learned**

A rule for merging a file by hand that keys on marker lines is wrong when
the file can hold a stray marker as text: the master diary had two. Check
what a merge deletes (`git diff --stat` against the base) before a push.
The determinism test that CLAUDE.md rule 5 describes as running the corpus
at two `--jobs` values does not build a program; nothing in the gates
compares two `--jobs` values of `build`.
