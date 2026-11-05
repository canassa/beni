## 2026-11-06 00:42 CET — `^` gives a `Float`, and `^^` is the integer power

**What I did.** Built #1985, the owner's design of 2026-11-05: `^ : number, number2 → Float`, and
`^^ : Int, Int → Int` (`Basics.ipow`), exact with `*`, `1 // (x ^^ n)` for a negative exponent, a
fractional exponent cut toward zero, and what `**` gives for Infinity or NaN (Cesar, q2). Specified
it in `language.md` §6.5 and §6.8 and in `checker.md` first, then the lexer, parser, BIR, checker
hint, formatter and frontend artifact version 30. Migrated each `^` that needs an `Int`. Asked the
owner two more questions: the two fixtures that made `half = 2 ^ (0 - 1)` are now `run/` projects
with a test platform whose `foreign half : Int` is `0.5` (q3), and the list trie doubles with a
private `twoTo` in place of `^^` (q4). Rebased twice onto master after #990 merged.

**What I learned.** `^^` in the trie made every page that can grow a list ship `ipow`, +54 to +123
brotli bytes; a doubling helper costs +5 to +48 on the pages. The shape of that helper counts: the
accumulator loop gave Conduit +166 and the one-line recursion `2 * twoTo (k - 1)` +114, and part of
each is only the short names that move by one letter after a new function. A size base must build
the same modules: the base compiler could not parse `^^` in `bench/corpus/DictExtra`, dropped the
module, and made the line look +740 where it is +94. A rebase can push a file over a gate's limit
with no conflict: master's new text and my one line put `SKILL.md` 29 bytes over 8 000. A helper
that a worded declaration runs needs its own pin in `word-bodies.txt`; a placeholder hash makes the
test print the real one.
