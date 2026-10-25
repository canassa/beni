## 2026-10-25 02:13 CEST — a fold over unit lists keeps its result

**What I did.** #952: `lfold xs = List.foldl xs [] λx d → List.push d x` at
`List ⊤` published no result, so a push onto a top-level list it made was
accepted under `--ownership-everywhere`. The cause is in `mayShare`, the
type test for "may these two values be one object": it compares two
applications argument by argument with itself, and `⊤` against `⊤` is
false because `⊤` is not an object. So `List ⊤` could never be `List ⊤`,
and the call dropped the fold's `π2` as a result the type rules out. Type
arguments that are both `⊤` or both `{}` now agree (`argsMayAgree`).
Fixture `ownership/FoldUnitTopLevel` (red on master by reverting the file),
with a custom-type wrapper and a local control. A whole-corpus verdict
sweep (3 858 checks under `--ownership-everywhere`, base vs head) moved only
the new fixture.

**What I learned.** Applications' arguments ask "may these be one type",
not "may these be one object": the two questions differ exactly where a
type has no object, `⊤` and `{}`. `Set t = Dict t ⊤` makes it matter.
