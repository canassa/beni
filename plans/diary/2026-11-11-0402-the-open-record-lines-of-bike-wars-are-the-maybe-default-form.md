## 2026-11-11 04:02 CET — the four open record lines of bike-wars are the Maybe default form

Part of #2477. Part of #1018.

**What I did**

- The four open record lines of `examples/bike-wars` have a reason: `Game.pureUpdate` has the form `m ▷ Maybe.map (f model _) ▷ Maybe.withDefault model` (R-4.2.3), which `ownership/MaybeDefault` pins. v1 accepts it, and v2 refuses its record lines.
- The pinned number of open entries is 92. 169 of the 261 lines have a reason after six steps.

**What I learned**

- The join rule of the first step missed these four lines for a plain cause: the handler of `bike-wars` writes a record and no list, so the call had no list line to join with. The fixture of the same form writes a list. A rule that needs a partner line is blind where the partner cannot exist.
- I wrote first that v2 refuses the form "until it reads the contract of `Maybe.map`". I did not measure that. I measured that the fixture has the same form, that v1 accepts it, and that the fixture's list line is under #1704. I stopped the gates, changed the sentence to those three facts, and ran the gates again. Seven minutes are cheaper than a sentence in the specification that I cannot prove.
- An example program of the repository does not build under checker v2 with enforcement. That is the kind of fact that a list of 261 lines hides, and that one line with a reason shows.
