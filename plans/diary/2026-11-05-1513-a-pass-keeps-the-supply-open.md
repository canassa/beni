## 2026-11-05 15:13 CET — A pass keeps the supply open

**What I did.** Answered Finding 5 of #1981. A label passed on inside a known code keeps the callee entry's open mark, so
`go v f = app v λz → f z` is `ε… π1ε*` as `app` is, and a write inside another callback reaches the outer call.

**What I learned.** The suspected cause was `below` lost on the way out through `sepLeaf`. It was not: `main` had no
demand at all, so the write itself never got there, and no condition can be asked of a demand that does not exist. An
empty line in a dump is the finding. My first fix opened every pass and broke an accepted fixture; the code already had
the discriminator, `at_site`, and a helper I wrote to find it was wrong for a reason a fixture showed in one run.
