## 2026-10-23 05:57 CEST — the level refusal (§16.7 (e))

**What I did.** Gave #286's (e) its own cause, `level`. A projection that takes one level out
of a recursive type's marker now makes its entries approximate as *another level*
(`approx_level`), whatever made them approximate before. A holder found so is `level`. So is a
holder of the written cell itself when the cell stands for several levels, and an operand of a call
that reaches the cell only that way. The message (`list_may_be_shared`) says that the checker
cannot tell the levels apart, writes the copy, and names `language.md` §6.8, which now states
the limit with the `alternate` example. The project is `build/bad/everywhere/OwnershipLevel`,
because `build/bad/direct/` went with `browser-direct`. The fixture is `ownership/LevelLimit`,
with exact twins that keep `alias` and `later-use`. The skill has a *Recursive values* section.

**What I learned.** Most marker refusals reached the holder through a call, often an argument that
the callee returns at two result paths, so the first draft gave even `alt` the cause `call`. The
marker is what a copy at the construction removes, so it now takes precedence once the path goes
through one. No verdict moved. Eight goldens changed their cause from `element` or `call` to
`level`. The draft message's construction-site fix needs a place the report does not carry. The
amendment says so, and the message writes the copy at the edit and names the construction in words.
