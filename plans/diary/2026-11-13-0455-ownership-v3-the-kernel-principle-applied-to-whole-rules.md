## 2026-11-13 04:55 CET — ownership v3: the kernel's principle applied to whole rules

**What I did.** Fixed the faults of reports 118 and 119 by rule, not by fault (research report 120). The
entry rule of `src/own3/` now takes a model location as `update`'s own only where every source of it, in
`init`, `update` and `settle`, is a new cell let go nowhere or an `own` model location let go nowhere;
the message is never `own`. The fold answer reads the same three facts for a new cell as for a parameter.
A derived `eq` or `compare` applies what its parts' methods do, found through the dispatch terms
(`Edges.termsEdges`), with a published fact per derived row for other modules. Markup holds the locals its
holes read (#2505, which also fixed #2506). A chain of writes visits each entry once, and a type past 4 096
locations is a loud limit. An adversarial reviewer found two older holes (a handler in a hole was not
escaped; a `Js` literal with no element step dropped its items), fixed too. Kernel §6.4, §6.8, §6.11,
§6.12, §6.13 and §8 changed.

**What I learned.** The sweeps (76 138 programs) went from 78 traps and crashes to 0; real writes from 292
to 287 of 308. Each lost write needs a fact that is a platform's to give: that a command's message is
handed once (todo), or a precise row for `Cmd.map`'s function (conduit, lost through the `Js` literal
fix). The layout limit had to be measured: 16 384 locations cost 6 s to check, 4 096 cost 0.5 s. Two
agents on one build lock serialise everything; batching sweeps, base tests and measurements under one
lock hold saved most of the waiting.
