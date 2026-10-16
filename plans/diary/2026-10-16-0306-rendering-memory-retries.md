# 2026-10-16 — Separate chosen compiler caps from measured endpoints

The unchanged nested TEA app at N3,888 failed under the sweep's 16 GiB
address-space cap but compiled under 24 GiB. Its normalized rendering response
is 513,666 brotli bytes. Retain both attempts: the lower cap was a budget choice,
not evidence that this curve cannot reach the requested target.

A checkpointed probe driver retries the four other capped TEA families with
the same compiler and source, reserving the whole six-slot, 26,000 MiB resource
pool during compilation. It uses the ordinary pricing worker and continues
below-target successes to another measured input. Exact source/compiler identity
and a strictly larger recorded cap are required to supersede a failed attempt.
The HTML report displays recovered points and retains original failures in its
provenance; native and normalized output hashes join the two ledgers.

This checkpoint contains 2,404 sizes, including 982 stress measurements and
29 target crossings. Fifteen curves currently retain failed compiler endpoints;
four of those have larger-cap retries pending. Artifact audits verified all
982 stress outputs and their native counterparts. The report's recovery section
renders in Chrome without JavaScript errors or mobile page overflow. Research
106 is 1,993 whitespace-separated words. The size sweep continues.

No repository gates or suites, and no new application timings ran.
