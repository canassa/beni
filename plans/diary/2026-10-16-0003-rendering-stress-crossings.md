# Rendering stress crossings and live fits

The size-only follow-up to #172 / PR #180 now retains 392 additional measured
bundles, with six actual 512 kB brotli crossings. Mixed TEA/A/B/C/D and list TEA
crossed; direct has two explicitly recorded compiler-memory limits. Mixed C
reached 525,605 bytes at 9,616 varied components, B 524,091 at 9,264. At the
common N8,768, C is 478,849 bytes versus B 497,031 and vanilla 48,433.
The full family sweep remains in progress; no failed or unfinished curve is
extended using estimated sizes.

The standalone HTML report adds baseline/slope/error fits, a stress-only zoom,
a family slope matrix and the larger measured curves. Three process queues
rotate families, with shared CPU/memory admission and bounded parallel BIR
dumps. Repeated identical compression inputs are memoized within one byte
account; all seven complete sample accounts stayed exactly equal. Scheduling
and resource amendments are retained with compiler/source identities.

Chrome checked the report controls and mobile width. Snapshot integrity checks
verified 182 primary, 125 secondary and 84 tertiary output artifacts. The
historical manifest still verifies its original bundles and prior validation
artifacts; no application timing, repository gate or test suite was run.
