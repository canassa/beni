## 2026-11-06 22:30 CET — A refusal for want of a contract

**What I did.** After a second review of #2153: `host` now says what a value's call answers in §2.3.4 and §2.14.2, §2.14.5 walks H1–H6 for the route with a refused program per row, the arm join landed, and `SanitiserValueKept`, `SanitiserValueCallQueue` and `SanitiserValueCallRuns` pin it. Left on #2163: `Walk`'s unknown-code answer.

**What I learned.** I had called 896 refused programs "proven unsound", and they weren't: they run correctly. A witness of the same form shows that a caller can't be accepted on today's block, which is a statement about the block, not about those programs. Say which of the two a refusal rests on. Also, an arm join turned my fixture's `if` value from "no contract" into a precise one without any test failing, so a fixture has to be read again when a route it pins moves.
