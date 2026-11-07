## 2026-11-05 15:44 CET — Rebase the slot state on the taken element

**What I did.** Rebased #2009 on #1981, removed `CellEdit.elementEdit`, and took block version 22. Filed #2018 for the sound
programs the cell rules refuse.

**What I learned.** Two rules for one defect were one too many: the store rule covers every red of #1981's fixture, each
with its real cause, and `BallMachine`'s element edit comes back. The element edit in a helper is sound by itself, and the
refusal belongs at the caller, where the store is seen. Size targets at their limit make a rebase a line-counting exercise:
two merged slices that each fit can overflow together. And a scratch clean-up must not take a reviewer's probes with it:
I deleted `rev/fx` and the fuzz scripts while the review could still need them.
