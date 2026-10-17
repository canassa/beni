## 2026-10-15 20:37 CEST — Publish compile-to-vanilla research

**What I did**

Prepared the research-only PR for #172 at the owner's request. Normalized
trailing whitespace in the generated SVG figures and their generator, refreshed
the artifact manifest, and retained the measured bundles and samples unchanged.
The PR requests Claude review and must remain unmerged.

**What I learned**

The owner explicitly instructed this session not to run gates or repository
suites on this machine for this research-only task. This supersedes the earlier
session entry's plan to run them. No further suites were run. Reading the prior
log showed the earlier attempt ended when the build_id compiler process received
SIGKILL; it did not establish a passing repository suite.
