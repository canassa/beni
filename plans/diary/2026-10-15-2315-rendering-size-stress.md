# Rendering size stress report

The owner narrowed #172 to bundle size and requested an HTML report with real
curves through about 512 kB brotli. Added an offline interactive report, local
viewer, checkpointed adaptive size sweep, per-family curves, marginal slopes
and downloadable data. The original generator remains unchanged; larger apps
repeat its ten varied UI families, without padding.

The campaign is still running on azathoth. Its first normalized rendering
crossing is TEA at N=3,888: 579,185 brotli bytes. The B/C ordering changes
across larger points, invalidating an unconditional C-only conclusion from N32.
Direct exhausts host memory at mixed N1,728 (about 30 GB resident), filed #203;
a separate grouped-source probe also fails under a 16 GiB cap. Failed native
curves remain visibly incomplete. Other curves continue to their own crossings.

Addressed the previous review's real alias/dependency findings in the research
lowerer. Thirty current adversarial outputs match TEA; seven old outputs
diverge. All 792 originally priced candidate sources remain byte-identical.
No compiler/runtime implementation changes, repository gates or suites.
