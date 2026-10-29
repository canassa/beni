## 2026-10-29 17:16 CET — Correction: prerendering runs under Node, not an embedded engine

**What I did.** Corrected `prerender.md` §5.1, §10 question 1, §9 and §11. The entry
`2026-10-29-1350-prerender-engine-decided.md` says the owner chose an engine embedded in `beni`.
That is wrong: the owner's "go with the recommendation" meant the document's recommendation,
Node, and I read it as my own leaning. The embedded engine, slice P5 and `prerender_unsupported`
are withdrawn. Research 108 keeps a note at its top and stays as the measurement of the option.
Issue #1177 (`Url.fromString` written in beni, needed only because QuickJS has no `URL`) is closed
as not planned, and its PR #1184 is closed unmerged.

**What I learned.** When the owner answers "go with the recommendation" and two recommendations
are in play (the document's and mine), ask which one before writing it down as a decision. One
misread decision started a research lane and an implementation lane that each followed it
faithfully.
