## 2026-11-04 14:27 CET — Explain rejected numeric ASCII binds

**What I did**

Added the negative-comparison spacing hint to a numeric right-hand side rejected inside a block, as well as the already covered arrows outside blocks. Added a focused parser fixture and recorded the pre-fix diagnostic.

**What I learned**

Inside a block the arrow is valid syntax, so the rejection points at its numeric right-hand side. Checking that the number follows an ASCII bind gives the hint without changing valid binds or Unicode diagnostics.
