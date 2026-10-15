## 2026-10-15 13:25 CEST — a dollar sign in front of every compiler-made name

**What I did**

Took Cesar's answer to `emit-cache-q4`: every compiler-made name gets a
`$` in front, and a declaration's numbered compiler-made names come from
one source. Recorded it in `backend.md` §4, then made `Lowerer.fresh`
spell every name `$<hint>$<n>` and refuse the hints that would print as a
positional name (`m`, `in`, `l` and digits); the `dom` lowering's patch
inputs ask for `input` instead of `in`. The two pages that threw moved
from `tests/pending/` to `tests/corpus/browser/dom/` (CK-232 fixed); both
are red without the change. Taught the `dom` oracle the new spelling,
re-blessed the `emit/` goldens and recorded every run hash again.

**What I learned**

Against the numbering commit, on 654 programs in development and
release: 1 003 of 1 308 builds are byte-identical, every other `.mjs`
differs only in a `$` in front of 12 550 compiler-made name tokens and
`in` → `input` in 1 305, and only the two new pages change in release,
which is the fix. Maps keep every source position but lose 3 853 names:
the printer named a compiler-made identifier by its hint (`made`,
`update`) as if it were a source name, and a `$` name now carries none.
The release printer had already given the two colliding names of the
master page one short name, `d`, so release threw too.
