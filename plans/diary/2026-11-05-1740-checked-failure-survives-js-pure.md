## 2026-11-05 17:40 CET — A checked failure survives Js.pure (#1999, second review)

**What I did**
- Applied the second review of #1999, which the owner approved. F1: `boundary.md` §4 and §4.2 no longer promise that `foreign pure` and `Js.pure` throw nothing in a checked build. `backend.md` §16.6 now says that the failure fact is separate from the rung and survives wrappers, callable aliases and modules. It names the code that trusts the rung today: `Totality.zig` and the lowering's eager-markup tests. That work went into step 3 of §16.8, and §16.7 gained the unread `round`/`Float.log` fixtures. `language.md` §13.8 has the same rule. F2: byte identity now holds only for the same source tree, across `--jobs` and cache state; declaration order is about acceptance and behaviour. C1: corrected #1992's explanation. The `Random.int` threshold is `2³²` for every range above it, not `range - 1`.
- Merged master into the branch. Added new commits only.

**What I learned**
- A rung is a promise about effects, and a check is not an effect. When the two shared one word ("pure means total and non-throwing"), the old word would have quietly erased the new fact. Any document that defines a word by two properties needs re-reading when one of them changes.
- "Byte-identical across declaration order" read as determinism and was something else. Determinism compares two runs of one input. A reordered file is a different input, and its source map must differ.
- I copied a modular-arithmetic explanation without working an example. One line of arithmetic with `range = 2³³ + 1` would have shown the threshold is `2³²`.
