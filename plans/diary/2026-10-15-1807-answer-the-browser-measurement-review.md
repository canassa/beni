## 2026-10-15 18:07 CEST — Answer the browser measurement review

**What I did**

Addressed the requested review of PR #147 using its existing observations:
published both sweep pages, qualified Sternhalma's bimodal distribution,
separated census populations and stated each literal row-swap criterion.
Strengthened the audit to verify page membership and recorded execution order.
The updated audit passes and the full Linux gate passes after the analysis
code changes. No timing or native Chrome replay was added.

**What I learned**

A pooled median can hide two different page clusters or a bimodal app
distribution. Two shifted sweep orders do not counterbalance all positions.
The original two-subject Conduit loop was confounded; the historical
three-subject comparisons still rotate correctly. The zero-root statement
was always Conduit's, not the whole corpus. The recommendation remains to
stop the present direct design, with the owner retaining the decision.
