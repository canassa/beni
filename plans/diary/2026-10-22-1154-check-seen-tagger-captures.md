## 2026-10-22 11:54 CEST — Check seen tagger captures

**What I did**

Continued #210 with the owner's clarification that only list demands are in
scope. Posted the staged record inventory on #315 for R4 and linked it from
#210. Found three rejected subscription taggers in imported test platforms
that the check-only audit missed, and opened #709. Proved the scalar-message
wrapper red in tests/pending before applying the existing conditional
retained-capture proof to seen sending taggers. Promoted that fixture and
added a rejected list-bearing caller. All existing ownership goldens passed
unchanged in the focused comparison. The three platform reports are clean.

**What I learned**

The checker already represents the empty-capture condition as self
separation. Its use was limited to unseen taggers even though the same
retention rule applies when calls are seen. Reusing that proof clears the
wrapper without granting ownership of a captured list. The pending runner
also reports an unrelated stale EnumCycle entry in RED; the new fixture
itself was red for its recorded ownership-report mismatch.
