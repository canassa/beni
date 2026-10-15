## 2026-10-15 10:28 CEST — finish the ownership bridge fix audit and review

**What I did**

Opened PR #124 and requested `@claude review`; it found no blocking defect.
Answered every point, adding early-result, nested-recursive, nested-loan,
accepted nested-fold and carried-capture coverage. Those fixtures and formatting
checks pass. The unchanged checker code's hosted Linux CI is green.

Completed the full bridge: the exact same 116,456 inputs, 43,066 translations
and value checks, 73,390 skips and five stream hashes. Total original program
leads fell from 2,358 to 1,725. The audit ran both Lean interpreters on every
remaining original, with complete traces and original-source fidelity checked:
201 confirmed unsafe originals became 0. All 401 reverse leads remain refused
with identical details. Retained the full campaign evidence, interpreter
judgments, app diagnostics and a before/after report. The CI-bound confirmed
count is 7 → 0; its total leads are 15 → 6. No application or ownership
permission changed, and PR #124 remains unmerged.

**What I learned**

The general rules also refuse 432 historical leads that agreed on the one
executed input; that finite agreement cannot discharge a static sharing
obligation. `?` remains its own BIR transfer, consuming its operand and keeping
the Err payload; the missing consumption was inside a compound result used by
that operand. A nested callback result the loan walk cannot follow remains
refused by returns-owned rather than acquiring an ownership permission.
