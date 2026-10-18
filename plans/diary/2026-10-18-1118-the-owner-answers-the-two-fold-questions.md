## 2026-10-18 11:18 CEST — the owner answers the two fold questions

**What I did**

I recorded the owner's answers to questions 1 and 2 of
`2026-10-18-0324-open-questions-while-the-owner-is-away.md` (issue #286).

- **Question 1, the cast marker (F2): option (iii), make the check scale.** It is the only option
  consistent with the no-limits rule: (ii) tunes a cap and (i) loses precision. There are two
  conditions.
  - **The marker records the full type, not its head.** `Maybe String` and `Maybe (List Int)`
    looking alike is a soundness gap (the #348 review). Fixing it is required whatever it costs.
  - **It is not S1 work.** It comes after the 1.8× byte gap of S1's N = 1 app is understood. The
    measurement comes back to the owner before anything is built.
- **Question 2, `lvl` (d): yes,** as its own PR with its own review. It closes a known unsound
  acceptance on master (`tests/pending/ownership/ParamHole`), which the owner rates worse than any
  byte. It does not depend on question 1, so the two are not chained. It is ordered after the
  1.8× gap, like question 1.

Also this session:
- I merged #348, the fold-point design, after its review was answered.
- I merged Jayson's #333, the node HTTP server spec, and moved its stacked #346 onto master
  without merging it.
- I sent #350's review findings to the S1 implementer. The main one is that the `lost` bit is
  missing where a cap fires, so a capped write would get the language-rule message.

**What I learned**

- **The owner orders soundness above bytes.** The order is still S1 first, though: a soundness
  fix is its own PR, never folded into slice work.
