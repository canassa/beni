## 2026-10-15 11:43 CEST — number compiler-made names within each declaration

**What I did**

Took Cesar's answer to `emit-cache-q3`: the counter behind `$t$N`, `$p$N`
and the other compiler-made names restarts at 1 for each top-level
declaration, with one count through it and its nested functions. Recorded
it in `backend.md` §4 (*A compiler-made name is numbered within its
top-level declaration*), then made `Lowerer.restartNames` run before each
declaration's body and suspendable body, each schema part and each derived
function or primitive comparator. Re-blessed 22 `emit/` goldens, recorded
every run hash again with `zig build test-run-hashes`, taught the `dom`
oracle's extractor to read clones and walks per top-level statement, and
added a black-box test that is red without the change.

**What I learned**

On 638 corpus programs, development and release, built by master and by
the change: 795 of 1 276 builds are byte-identical; every other `.mjs`
differs only in the numbers once each top-level statement's `name$N`
tokens are numbered by first use, and every other `.map` maps the same
source positions and names, only at other generated columns. Six release
builds of `Http` pages, and the `emit/release/tea/HttpSendTracked` golden,
grow by 2 bytes: the release printer's "declared twice" bit
(`Opt.Plan.repeated`) is per name across the module, and a suspendable
body that binds a counted name twice now marks that name in every
declaration, as a local's own number always did. The printer then keeps
one `else` block it used to splice. The `dom` oracle read `r$N` and `w$N`
across the whole module, so it took one declaration's walks for
another's once the numbers repeated.
