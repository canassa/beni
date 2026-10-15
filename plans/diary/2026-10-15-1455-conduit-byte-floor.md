## 2026-10-15 14:55 CEST — Conduit byte floor

**What I did**

Read CLAUDE.md and research 97/98/99, then built pinned established Solid and
vanilla Web Components Conduit references locally. Archived production JS/maps,
lockfiles, source adjustments, byte accounting and Chrome smoke observations in
bench/conduit-floor. Wrote research 101, leaving 100 for S8. No compiler, platform,
core, application, budget or run-hash source changed; azathoth was not used.

**What I learned**

Adjusted Solid is 16,270 B over nine chunks or 13,085 B as one actual Rollup
chunk, versus tea 31,389 and current direct 37,970. Vanilla's adjusted 11,684 B
lacks features and is not a parity floor. Stock Solid's favorite callback throws
on an undefined slug; the adjusted build repairs it. Removing direct's positional
entry prologues saves only 90 B; a combined protocol deletion saves 2,600 B before
replacement code. A lexical/AOT selection redesign has a conditional 1–3 kB
planning target, not a demonstrated saving. Local constituent checks have 1,329
passes, 15 skips and the two known macOS case-folding failures; the Linux budget
gate remains owed. The PR is to be reviewed and left unmerged.
