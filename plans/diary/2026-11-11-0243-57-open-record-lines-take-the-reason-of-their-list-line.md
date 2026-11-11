## 2026-11-11 02:43 CET — 57 open record lines take the reason of their list line

Part of #2477. Part of #1018.

**What I did**

- 57 of the 261 record lines that #2478 pinned as `open` have a reason now. Each one is at the position of a known list line, with the same pair of verdicts and the same base. The two lines are one call's demands, so the record line takes the list line's reason and names that line.
- The known list has a section for them. Only reasons changed, and no key. 204 lines stay `open`.

**What I learned**

- The cheapest classification was in the list already. A call that differs between the checkers has a list line and a record line, and somebody had written the reason for the list line months or days before. I looked for new causes first and for known ones second. The other order is faster.
- The largest group of #2477 was the form `m ▷ Maybe.map (handle model _) ▷ Maybe.withDefault model`. I took it for an over-refusal of v2 with no rule. v2 has the rule (R-4.2.3). It cannot use it, because it reads core's `Maybe.map` as pessimistic until #1704. The list line of the same call said so.
- The rule joins by position, verdicts and base. That is evidence and not a proof, so I read each of the 57 pairs before I wrote that they are one call's demands.
