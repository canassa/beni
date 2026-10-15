## 2026-10-12 14:01 CEST — ownership oracle: second review answered

**What I did.** Answered the second adversarial review of `proofs/ownership`. Restated `Invariant`
(observers related, escaped naming, live field paths, path-wise description, dead bindings stay named,
unbounded correspondence) and Lemma 6.7 (captures, shared results, observer-only clause 2, guards);
the review's counterexample is a guarded example proved excluded. Added `ownership falsify`, which
executes the three sorry statements on random configurations and on every call of generated programs.
Fixed the in-place focus write-back (stale container) and the traversal length read. The axiom audit
now covers every constant and scans sources for sorry/admit/native_decide/axiom. A forked agent built
generator v5 (own declarations, recursion, branch arms), the branch-live control, distinct counts, the
aliased-write metric and precision, and made `ci` require generator catches.

**What I learned.** Executing a sorry statement is cheap and finds falsehoods fast: eleven ways the
statements were false or vacuous, and two real summary-checker defects (a once callback called by a
callee was neither consumed nor had its written captures demanded; `close`'s unused source made the
second reachable). recwrites and symenv are masked by neighbouring rules; keepsany is argued equivalent.
